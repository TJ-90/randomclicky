//
//  LLMProviderConfiguration.swift
//  leanring-buddy
//
//  Reads a local JSON config file the user places on disk so the runtime
//  brain can be switched to an OpenRouter vision model without shipping
//  any API key in the app binary or the Cloudflare Worker.
//
//  Expected file location:
//    ~/Library/Application Support/Clicky/llm.json
//
//  Expected JSON schema:
//    {
//      "provider": "openrouter",
//      "apiKey":   "sk-or-...",
//      "model":    "google/gemma-4-26b-a4b-it:free"
//    }
//
//  When the file is absent, unreadable, contains invalid JSON, or has an
//  empty apiKey the loader returns nil and the app falls back to the
//  default Claude-via-Worker path. It never crashes on a bad file.
//

import Foundation

struct LLMProviderConfiguration {
    let provider: String
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

    /// Reads and decodes the local llm.json config file.
    ///
    /// Returns nil (never throws) when:
    ///   - the file does not exist at the expected path
    ///   - the file is unreadable (permission error, corrupt bytes)
    ///   - the JSON is malformed or missing required keys
    ///   - the apiKey field is present but empty / whitespace-only
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

        guard let provider = jsonObject["provider"] as? String,
              let apiKey = jsonObject["apiKey"] as? String,
              let model = jsonObject["model"] as? String else {
            print("⚠️ LLMProviderConfiguration: llm.json is missing one or more required keys (provider, apiKey, model)")
            return nil
        }

        // Reject empty or whitespace-only apiKey — an empty key would silently
        // produce 401 errors every turn, which is worse than falling back to Claude.
        let trimmedApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApiKey.isEmpty else {
            print("⚠️ LLMProviderConfiguration: llm.json apiKey is empty — falling back to default provider")
            return nil
        }

        return LLMProviderConfiguration(
            provider: provider.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedApiKey,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
