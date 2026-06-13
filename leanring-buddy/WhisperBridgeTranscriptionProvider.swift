//
//  WhisperBridgeTranscriptionProvider.swift
//  leanring-buddy
//
//  Local transcription backend that runs OpenAI Whisper through a small Python
//  bridge script (clicky_transcribe.py) using the user's own Python interpreter
//  — the same Whisper install the user already runs in their AudioX project.
//
//  WHY THIS EXISTS
//  ─────────────────────────────────────────────────────────────────────────
//  Apple Speech (SFSpeechRecognizer) requires the macOS Speech Recognition TCC
//  permission, whose authorization prompt does not surface reliably for this
//  LSUIElement (menu-bar) app — so the recording aborted the instant it began
//  (the "millisecond waveform"). Whisper needs NO such permission, so
//  `requiresSpeechRecognitionPermission` is false and the recording proceeds.
//
//  SHAPE
//  ─────────────────────────────────────────────────────────────────────────
//  This is an upload-style (non-streaming) provider, mirroring
//  OpenAIAudioTranscriptionProvider: push-to-talk audio is buffered as 16 kHz
//  mono PCM16, assembled into a WAV on release, written to a temp file, and
//  handed to the bridge script. The bridge prints the transcript to stdout.
//
//  CONFIG (kept out of the binary / public repo)
//  ─────────────────────────────────────────────────────────────────────────
//  The Python interpreter path, bridge script path, and model name are read at
//  runtime from ~/Library/Application Support/Clicky/llm.json:
//
//    {
//      "provider": "ollama", "model": "qwen3.5:4b",
//      "whisperPythonPath": "/Users/you/anaconda3/bin/python",
//      "whisperScriptPath": "/Users/you/Downloads/Projects/AudioX/clicky_transcribe.py",
//      "whisperModel": "base.en"
//    }
//
//  These are machine-specific paths, so they live in the local config file —
//  never hard-coded in source.
//

import AVFoundation
import Foundation

/// Runtime configuration for the local Whisper bridge, read from llm.json.
/// Independent of LLMProviderConfiguration (which configures the *brain*); this
/// configures *transcription*. Returns nil when the required paths are absent.
struct WhisperBridgeConfiguration {
    let pythonExecutablePath: String
    let transcribeScriptPath: String
    let modelName: String

    static func loadFromDisk() -> WhisperBridgeConfiguration? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let configFileURL = applicationSupportURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("llm.json")

        guard FileManager.default.fileExists(atPath: configFileURL.path),
              let jsonData = try? Data(contentsOf: configFileURL),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        guard let pythonExecutablePath = (jsonObject["whisperPythonPath"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let transcribeScriptPath = (jsonObject["whisperScriptPath"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !pythonExecutablePath.isEmpty,
              !transcribeScriptPath.isEmpty else {
            return nil
        }

        let modelName = (jsonObject["whisperModel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModelName = (modelName?.isEmpty == false) ? modelName! : "base.en"

        return WhisperBridgeConfiguration(
            pythonExecutablePath: pythonExecutablePath,
            transcribeScriptPath: transcribeScriptPath,
            modelName: resolvedModelName
        )
    }
}

struct WhisperBridgeTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WhisperBridgeTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Local Whisper"
    // Whisper runs entirely locally and needs NO macOS Speech Recognition
    // permission — this is the whole point: it sidesteps the permission whose
    // prompt won't surface for this menu-bar app.
    let requiresSpeechRecognitionPermission = false

    private let configuration: WhisperBridgeConfiguration?

    init(configuration: WhisperBridgeConfiguration? = WhisperBridgeConfiguration.loadFromDisk()) {
        self.configuration = configuration
    }

    var isConfigured: Bool {
        guard let configuration else { return false }
        return FileManager.default.isExecutableFile(atPath: configuration.pythonExecutablePath)
            && FileManager.default.fileExists(atPath: configuration.transcribeScriptPath)
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Local Whisper is not configured. Add whisperPythonPath and whisperScriptPath to ~/Library/Application Support/Clicky/llm.json."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let configuration, isConfigured else {
            throw WhisperBridgeTranscriptionProviderError(
                message: unavailableExplanation ?? "Local Whisper is not configured."
            )
        }

        return WhisperBridgeTranscriptionSession(
            configuration: configuration,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class WhisperBridgeTranscriptionSession: BuddyStreamingTranscriptionSession {
    // Local Whisper is slow (Python start + model load + transcription is
    // ~4-10s), so the dictation manager's fallback timer must wait well past
    // that before giving up on us.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 25.0

    private static let targetSampleRate = 16_000

    private let configuration: WhisperBridgeConfiguration
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.whisper.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionProcess: Process?
    private var transcriptionTask: Task<Void, Never>?

    init(
        configuration: WhisperBridgeConfiguration,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
                self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionTask?.cancel()
        stateQueue.sync { transcriptionProcess }?.terminate()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) {
        let isEmpty = stateQueue.sync { isCancelled || bufferedPCM16AudioData.isEmpty }
        if isEmpty {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try runWhisperBridge(on: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Whisper Transcription] ❌ \(error.localizedDescription)")
            onError(error)
        }
    }

    /// Writes the WAV to a temp file, runs the Python bridge, returns its stdout.
    /// stderr is redirected to a temp file (not a pipe) so verbose Whisper
    /// progress output can't fill a pipe buffer and deadlock waitUntilExit.
    private func runWhisperBridge(on wavAudioData: Data) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let uniqueSuffix = UUID().uuidString
        let temporaryWavURL = temporaryDirectory
            .appendingPathComponent("clicky-voice-\(uniqueSuffix).wav")
        let temporaryStderrURL = temporaryDirectory
            .appendingPathComponent("clicky-whisper-stderr-\(uniqueSuffix).log")

        try wavAudioData.write(to: temporaryWavURL)
        FileManager.default.createFile(atPath: temporaryStderrURL.path, contents: nil)

        defer {
            try? FileManager.default.removeItem(at: temporaryWavURL)
            try? FileManager.default.removeItem(at: temporaryStderrURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.pythonExecutablePath)
        process.arguments = [
            configuration.transcribeScriptPath,
            temporaryWavURL.path,
            "--model",
            configuration.modelName
        ]
        // Run from the script's own directory so `import audiox_core` resolves.
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.transcribeScriptPath)
            .deletingLastPathComponent()

        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        if let stderrHandle = try? FileHandle(forWritingTo: temporaryStderrURL) {
            process.standardError = stderrHandle
        }

        stateQueue.sync { self.transcriptionProcess = process }

        do {
            try process.run()
        } catch {
            throw WhisperBridgeTranscriptionProviderError(
                message: "Couldn't launch the Whisper bridge (\(configuration.pythonExecutablePath)): \(error.localizedDescription)"
            )
        }

        // The transcript is small (one short utterance), so reading the stdout
        // pipe to EOF after the process closes it cannot fill the 64KB buffer.
        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let transcriptText = String(data: standardOutputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let stderrText = (try? String(contentsOf: temporaryStderrURL, encoding: .utf8)) ?? ""
            let stderrTail = String(stderrText.suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw WhisperBridgeTranscriptionProviderError(
                message: "Whisper bridge failed (exit \(process.terminationStatus)): \(stderrTail)"
            )
        }

        return transcriptText
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}
