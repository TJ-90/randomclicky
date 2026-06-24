//
//  CodexAPI.swift
//  leanring-buddy
//
//  Local Codex CLI bridge for screen-help turns.
//
//  Codex is not called as a remote REST API here. Clicky launches the user's
//  installed `codex` command in non-interactive exec mode, attaches the current
//  screenshots, and asks for a plain Clicky response that can flow through the
//  existing POINT, annotation, walkthrough, and act-mode parsers.
//

import Foundation

final class CodexAPI {

    // MARK: - Public

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        supplementalContextText: String?,
        configuration: LLMProviderConfiguration
    ) async throws -> String {
        let codexPrompt = Self.buildCodexPrompt(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            supplementalContextText: supplementalContextText,
            imageLabels: images.map { $0.label }
        )

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let responseText = try Self.runCodexExec(
                        images: images,
                        prompt: codexPrompt,
                        configuration: configuration
                    )
                    continuation.resume(returning: responseText)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Prompt

    static func buildPromptForTesting(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        supplementalContextText: String?,
        imageLabels: [String]
    ) -> String {
        buildCodexPrompt(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            supplementalContextText: supplementalContextText,
            imageLabels: imageLabels
        )
    }

    static func buildExecArgumentsForTesting(
        imageFileURLs: [URL],
        finalMessageURL: URL,
        configuration: LLMProviderConfiguration
    ) -> [String] {
        codexExecArguments(
            imageFileURLs: imageFileURLs,
            finalMessageURL: finalMessageURL,
            configuration: configuration
        )
    }

    private static func buildCodexPrompt(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        supplementalContextText: String?,
        imageLabels: [String]
    ) -> String {
        var sections: [String] = []

        sections.append("""
        You are the local Codex brain inside Clicky, a macOS screen companion.
        This is a screen-assistance turn, not a repository task. Do not inspect,
        edit, or run commands in any codebase. Use the attached screenshots and
        text context only.

        Return only the final Clicky response text. Do not include markdown,
        code fences, analysis, status text, or explanations about Codex. Clicky
        will speak normal prose aloud and show it in a small floating text box.
        If an action is appropriate, output Clicky's existing CLICK/TYPE tags;
        Clicky will ask the user for explicit confirmation before executing.
        """)

        sections.append("""
        Clicky response contract:
        \(systemPrompt)
        """)

        if !conversationHistory.isEmpty {
            let historyText = conversationHistory
                .suffix(10)
                .enumerated()
                .map { index, exchange in
                    """
                    prior exchange \(index + 1)
                    user: \(exchange.userPlaceholder)
                    clicky: \(exchange.assistantResponse)
                    """
                }
                .joined(separator: "\n\n")
            sections.append("Conversation history:\n\(historyText)")
        }

        if !imageLabels.isEmpty {
            let imageLabelText = imageLabels
                .enumerated()
                .map { index, label in
                    "attached image \(index + 1): \(label)"
                }
                .joined(separator: "\n")
            sections.append("Attached screen images:\n\(imageLabelText)")
        }

        if let supplementalContextText,
           !supplementalContextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(supplementalContextText)
        }

        sections.append("User transcript:\n\(userPrompt)")

        sections.append("""
        Final reminder: output only the Clicky response text. For normal answers,
        use natural speech. For visual help, include annotation tags inline and a
        POINT tag at the end. For confirmed screen actions, include CLICK/TYPE
        tags only when the current prompt says act mode is enabled and the target
        element ID exists in the current inventory.
        """)

        return sections.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Process

    private static func runCodexExec(
        images: [(data: Data, label: String)],
        prompt: String,
        configuration: LLMProviderConfiguration
    ) throws -> String {
        let fileManager = FileManager.default
        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("ClickyCodex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectoryURL)
        }

        let imageFileURLs = try writeTemporaryImages(
            images: images,
            temporaryDirectoryURL: temporaryDirectoryURL
        )
        let finalMessageURL = temporaryDirectoryURL.appendingPathComponent("codex-final-response.txt")
        let stdoutURL = temporaryDirectoryURL.appendingPathComponent("codex-stdout.log")
        let stderrURL = temporaryDirectoryURL.appendingPathComponent("codex-stderr.log")

        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            throw NSError(
                domain: "CodexAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create temporary Codex log files."]
            )
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let executableInvocation = try resolveCodexExecutableInvocation(configuration: configuration)
        let process = Process()
        process.executableURL = executableInvocation.executableURL
        process.arguments = executableInvocation.leadingArguments + codexExecArguments(
            imageFileURLs: imageFileURLs,
            finalMessageURL: finalMessageURL,
            configuration: configuration
        )
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.codexWorkingDirectory ?? "/tmp", isDirectory: true)
        process.environment = codexProcessEnvironment()
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()

        if let promptData = prompt.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(promptData)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(configuration.codexTimeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            throw NSError(
                domain: "CodexAPI",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Codex timed out after \(Int(configuration.codexTimeoutSeconds)) seconds."]
            )
        }

        let finalMessageText = readTextFile(finalMessageURL).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, !finalMessageText.isEmpty {
            return finalMessageText
        }

        let stdoutText = readTextFile(stdoutURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrText = readTextFile(stderrURL).trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0, !stdoutText.isEmpty {
            return lastUsefulLine(from: stdoutText)
        }

        let diagnosticText = tailText(stderrText.isEmpty ? stdoutText : stderrText, maximumCharacters: 1_200)
        throw NSError(
            domain: "CodexAPI",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Codex failed: \(diagnosticText)"]
        )
    }

    private static func codexExecArguments(
        imageFileURLs: [URL],
        finalMessageURL: URL,
        configuration: LLMProviderConfiguration
    ) -> [String] {
        var arguments: [String] = [
            "--ask-for-approval", "never",
        ]

        if configuration.codexDisableNonessentialFeatures {
            arguments.append(contentsOf: [
                "--disable", "apps",
                "--disable", "plugins"
            ])
        }

        arguments.append(contentsOf: [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", configuration.codexSandbox,
            "--cd", configuration.codexWorkingDirectory ?? "/tmp",
            "-m", configuration.model,
            "-o", finalMessageURL.path
        ])

        if !configuration.codexShouldLoadUserConfig {
            arguments.append("--ignore-user-config")
        }

        if !configuration.codexShouldLoadRules {
            arguments.append("--ignore-rules")
        }

        if configuration.codexUseOss {
            arguments.append("--oss")
        }

        if let codexLocalProvider = configuration.codexLocalProvider {
            arguments.append(contentsOf: ["--local-provider", codexLocalProvider])
        }

        for imageFileURL in imageFileURLs {
            arguments.append(contentsOf: ["--image", imageFileURL.path])
        }

        arguments.append("-")
        return arguments
    }

    private static func writeTemporaryImages(
        images: [(data: Data, label: String)],
        temporaryDirectoryURL: URL
    ) throws -> [URL] {
        try images.enumerated().map { index, image in
            let imageFileURL = temporaryDirectoryURL.appendingPathComponent("screen-\(index + 1).jpg")
            try image.data.write(to: imageFileURL, options: .atomic)
            return imageFileURL
        }
    }

    // MARK: - Executable discovery

    private struct CodexExecutableInvocation {
        let executableURL: URL
        let leadingArguments: [String]
    }

    private static func resolveCodexExecutableInvocation(
        configuration: LLMProviderConfiguration
    ) throws -> CodexExecutableInvocation {
        let fileManager = FileManager.default

        if let codexExecutablePath = configuration.codexExecutablePath {
            let expandedPath = NSString(string: codexExecutablePath).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expandedPath) {
                return CodexExecutableInvocation(
                    executableURL: URL(fileURLWithPath: expandedPath),
                    leadingArguments: []
                )
            }

            throw NSError(
                domain: "CodexAPI",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Codex executable was not found at \(expandedPath)."]
            )
        }

        for candidateURL in candidateCodexExecutableURLs() where fileManager.isExecutableFile(atPath: candidateURL.path) {
            return CodexExecutableInvocation(executableURL: candidateURL, leadingArguments: [])
        }

        return CodexExecutableInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            leadingArguments: ["codex"]
        )
    }

    private static func candidateCodexExecutableURLs() -> [URL] {
        var candidateURLs = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex")
        ]

        let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        candidateURLs.append(homeDirectoryURL.appendingPathComponent(".local/bin/codex"))
        candidateURLs.append(homeDirectoryURL.appendingPathComponent("bin/codex"))

        let nvmVersionsURL = homeDirectoryURL.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let nodeVersionURLs = try? FileManager.default.contentsOfDirectory(
            at: nvmVersionsURL,
            includingPropertiesForKeys: nil
        ) {
            let nvmCodexURLs = nodeVersionURLs
                .map { $0.appendingPathComponent("bin/codex") }
                .sorted { $0.path > $1.path }
            candidateURLs.append(contentsOf: nvmCodexURLs)
        }

        return candidateURLs
    }

    private static func codexProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? ""
        let commonPathEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let nvmBinEntries: [String] = {
            let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let nvmVersionsURL = homeDirectoryURL.appendingPathComponent(".nvm/versions/node", isDirectory: true)
            guard let nodeVersionURLs = try? FileManager.default.contentsOfDirectory(
                at: nvmVersionsURL,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }
            return nodeVersionURLs
                .map { $0.appendingPathComponent("bin").path }
                .sorted(by: >)
        }()

        let pathEntries = (existingPath.isEmpty ? [] : [existingPath]) + commonPathEntries + nvmBinEntries
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }

    // MARK: - Text helpers

    private static func readTextFile(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func lastUsefulLine(from text: String) -> String {
        text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty }) ?? text
    }

    private static func tailText(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let startIndex = text.index(text.endIndex, offsetBy: -maximumCharacters)
        return String(text[startIndex...])
    }
}
