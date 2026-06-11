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
        //   - unknown:    treat like openrouter and require a key so we fail
        //                 loudly rather than sending keyless requests
        let rawApiKey = jsonObject["apiKey"] as? String ?? ""
        let trimmedApiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let providerRequiresApiKey = trimmedProvider.lowercased() != "ollama"
        if providerRequiresApiKey && trimmedApiKey.isEmpty {
            print("⚠️ LLMProviderConfiguration: llm.json apiKey is empty for provider '\(trimmedProvider)' — falling back to default provider")
            return nil
        }

        return LLMProviderConfiguration(
            provider: trimmedProvider,
            apiKey: trimmedApiKey,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
