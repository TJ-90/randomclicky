//
//  LLMProviderConfiguration.swift
//  leanring-buddy
//
//  Reads a local JSON config file the user places on disk so the runtime
//  brain can be switched to a local or third-party vision model without
//  shipping any API key in the app binary or the Cloudflare Worker.
//
//  Expected file location:
//    ~/Library/Application Support/Clicky/llm.json
//
//  Supported JSON schemas:
//
//    OpenRouter (remote; API key required):
//    {
//      "provider": "openrouter",
//      "apiKey":   "sk-or-...",
//      "model":    "google/gemma-4-26b-a4b-it:free"
//    }
//
//    Ollama (local; no API key needed):
//    {
//      "provider": "ollama",
//      "model":    "qwen3.5:4b"
//    }
//    The "apiKey" field is optional for Ollama and ignored at runtime.
//
//    Codex CLI (local command; uses saved Codex auth):
//    {
//      "provider": "codex",
//      "model": "gpt-5.3-codex-spark",
//      "codexExecutablePath": "/Users/you/.nvm/versions/node/v22.17.1/bin/codex",
//      "codexTimeoutSeconds": 45,
//      "codexDisableNonessentialFeatures": true
//    }
//
//    Codex CLI through local Ollama / open-source provider:
//    {
//      "provider": "codex",
//      "model": "gpt-oss:20b",
//      "codexUseOss": true,
//      "codexLocalProvider": "ollama"
//    }
//
//  When the file is absent, unreadable, or contains invalid JSON the loader
//  returns nil and the app falls back to the default Claude-via-Worker path.
//  It never crashes on a bad file.
//

import Foundation

struct LLMProviderConfiguration {
    let provider: String
    /// The API key read from llm.json. Empty string for providers that do not
    /// require one (e.g. Ollama running locally).
    let apiKey: String
    let model: String
    /// When true, speak replies with the local macOS synthesizer instead of
    /// ElevenLabs/Worker — lets voice output work fully offline.
    let localVoiceOutput: Bool
    /// Optional absolute path to the Codex CLI binary. GUI apps do not inherit
    /// the user's shell PATH, so this lets nvm/homebrew installs be addressed
    /// directly when auto-discovery cannot find them.
    let codexExecutablePath: String?
    /// Directory Codex should run from. Defaults to /tmp so Clicky screen-help
    /// turns do not accidentally load repository instructions or edit files.
    let codexWorkingDirectory: String?
    /// When true, pass --oss to Codex so it uses an open-source/local provider.
    let codexUseOss: Bool
    /// Optional local provider value for Codex's --local-provider flag, such as
    /// "ollama" or "lmstudio".
    let codexLocalProvider: String?
    /// Sandbox policy passed to Codex exec. Defaults to read-only because Clicky
    /// performs screen actions through its own confirmation-gated AX executor.
    let codexSandbox: String
    /// Whether Codex should load ~/.codex/config.toml. Defaults false for speed
    /// and predictability; set true if you rely on Codex config profiles/tools.
    let codexShouldLoadUserConfig: Bool
    /// Whether Codex should load user/project execpolicy rules. Defaults false
    /// for screen-help turns that are not repository work.
    let codexShouldLoadRules: Bool
    /// Whether Clicky should disable Codex apps/plugins for faster screen-help
    /// turns. Clicky does not use Codex tool surfaces; actions execute through
    /// Clicky's own confirmation-gated AX pipeline.
    let codexDisableNonessentialFeatures: Bool
    /// Hard timeout for the local Codex process.
    let codexTimeoutSeconds: TimeInterval

    /// Returns true when the configured provider is OpenRouter.
    ///
    /// Used at the call site to decide whether to route a vision request
    /// through OpenRouterAPI instead of ClaudeAPI. Comparison is
    /// case-insensitive so "OpenRouter" and "openrouter" both match.
    var usesOpenRouter: Bool {
        provider.lowercased() == "openrouter"
    }

    /// Returns true when the configured provider is Ollama.
    ///
    /// Used at the call site to decide whether to route a vision request
    /// through OllamaAPI (localhost:11434) instead of ClaudeAPI or
    /// OpenRouterAPI. Comparison is case-insensitive so "Ollama" and
    /// "ollama" both match.
    var usesOllama: Bool {
        provider.lowercased() == "ollama"
    }

    /// Returns true when the configured provider is Codex CLI.
    ///
    /// Codex is invoked as a local process using the user's existing Codex auth.
    /// It is keyless from Clicky's point of view, like Ollama.
    var usesCodex: Bool {
        provider.lowercased() == "codex"
    }

    /// Reads and decodes the local llm.json config file.
    ///
    /// Returns nil (never throws) when:
    ///   - the file does not exist at the expected path
    ///   - the file is unreadable (permission error, corrupt bytes)
    ///   - the JSON is malformed or missing required keys (provider, model)
    ///   - the provider is "openrouter" and apiKey is absent or empty
    ///     (an empty key would silently produce 401 errors every turn)
    ///
    /// Unlike OpenRouter, Ollama does not require an API key, so an absent
    /// or empty apiKey is valid — and expected — for the "ollama" provider.
    ///
    /// The caller treats nil as "use the default Claude path".
    static func loadFromDisk() -> LLMProviderConfiguration? {
        // Resolve ~/Library/Application Support/Clicky/llm.json.
        // We use FileManager rather than hard-coding a tilde path so the
        // home directory is correct for the current user even in sandboxed
        // or multi-user scenarios.
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            // This should never happen on macOS, but guard defensively.
            return nil
        }

        let configFileURL = applicationSupportURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("llm.json")

        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            // File is absent — not an error, just use the default path.
            return nil
        }

        guard let jsonData = try? Data(contentsOf: configFileURL) else {
            print("⚠️ LLMProviderConfiguration: could not read \(configFileURL.path)")
            return nil
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("⚠️ LLMProviderConfiguration: llm.json is not a valid JSON object")
            return nil
        }

        // provider and model are required for every provider.
        guard let provider = jsonObject["provider"] as? String,
              let model = jsonObject["model"] as? String else {
            print("⚠️ LLMProviderConfiguration: llm.json is missing one or more required keys (provider, model)")
            return nil
        }

        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)

        // apiKey handling is provider-dependent:
        //   - openrouter: required, must be non-empty (empty key → silent 401s)
        //   - ollama:     optional, ignored at runtime (local server, no auth)
        //   - codex:      optional, uses saved Codex CLI auth or local OSS provider
        //   - unknown:    treat like openrouter and require a key so we fail
        //                 loudly rather than sending keyless requests
        let rawApiKey = jsonObject["apiKey"] as? String ?? ""
        let trimmedApiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let keylessProviders: Set<String> = ["ollama", "codex"]
        let providerRequiresApiKey = !keylessProviders.contains(trimmedProvider.lowercased())
        if providerRequiresApiKey && trimmedApiKey.isEmpty {
            print("⚠️ LLMProviderConfiguration: llm.json apiKey is empty for provider '\(trimmedProvider)' — falling back to default provider")
            return nil
        }

        let localVoiceOutput = (jsonObject["localVoiceOutput"] as? Bool) ?? false
        let codexExecutablePath = (jsonObject["codexExecutablePath"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codexWorkingDirectory = (jsonObject["codexWorkingDirectory"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codexUseOss = (jsonObject["codexUseOss"] as? Bool) ?? false
        let codexLocalProvider = (jsonObject["codexLocalProvider"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codexSandbox = (jsonObject["codexSandbox"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCodexSandbox: String
        if let codexSandbox, !codexSandbox.isEmpty {
            resolvedCodexSandbox = codexSandbox
        } else {
            resolvedCodexSandbox = "read-only"
        }
        let codexShouldLoadUserConfig = (jsonObject["codexShouldLoadUserConfig"] as? Bool) ?? false
        let codexShouldLoadRules = (jsonObject["codexShouldLoadRules"] as? Bool) ?? false
        let codexDisableNonessentialFeatures = (jsonObject["codexDisableNonessentialFeatures"] as? Bool) ?? true
        let codexTimeoutSeconds = (jsonObject["codexTimeoutSeconds"] as? Double) ?? 45

        return LLMProviderConfiguration(
            provider: trimmedProvider,
            apiKey: trimmedApiKey,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            localVoiceOutput: localVoiceOutput,
            codexExecutablePath: codexExecutablePath?.isEmpty == true ? nil : codexExecutablePath,
            codexWorkingDirectory: codexWorkingDirectory?.isEmpty == true ? nil : codexWorkingDirectory,
            codexUseOss: codexUseOss,
            codexLocalProvider: codexLocalProvider?.isEmpty == true ? nil : codexLocalProvider,
            codexSandbox: resolvedCodexSandbox,
            codexShouldLoadUserConfig: codexShouldLoadUserConfig,
            codexShouldLoadRules: codexShouldLoadRules,
            codexDisableNonessentialFeatures: codexDisableNonessentialFeatures,
            codexTimeoutSeconds: max(5, codexTimeoutSeconds)
        )
    }
}
