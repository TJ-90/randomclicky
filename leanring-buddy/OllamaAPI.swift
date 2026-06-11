//
//  OllamaAPI.swift
//  leanring-buddy
//
//  Non-streaming Ollama chat-completions client for local vision requests.
//
//  Ollama exposes the same OpenAI-compatible /v1/chat/completions endpoint as
//  OpenRouter, so the JSON body shape and response parsing are identical. The
//  key differences from OpenRouterAPI are:
//    - Base URL is http://localhost:11434/v1/chat/completions — no TLS, no
//      remote host, so there is nothing to warm up and no TLS session to cache.
//    - No Authorization header is required. Ollama ignores the Authorization
//      header entirely when running locally; we send a dummy "Bearer ollama"
//      value so the request is structurally identical to other providers and
//      any intermediate proxy (Charles, mitmproxy) does not flag a missing
//      header as suspicious.
//    - No attribution headers (HTTP-Referer, X-Title) — those are OpenRouter-
//      specific and Ollama does not recognise them.
//    - Timeout values are much longer: local inference on an M1 4.7B model
//      can take 30–90 seconds for a cold start. The default 60s URLSession
//      timeout WILL fire before the model finishes loading. We use 180s for
//      the request and 240s for the resource to give the cold-start loader
//      comfortable headroom without hanging indefinitely on a genuine failure.
//    - The configured model (e.g. "qwen3.5:4b") is a reasoning model. Ollama's
//      OpenAI-compat layer puts the final answer in choices[0].message.content
//      with no <think> tags — we parse content exactly like OpenRouterAPI with
//      no post-processing needed.
//
//  Connection-refused / timeout errors produce a user-friendly message that
//  the caller can speak aloud without modification.
//
//  Supported llm.json schema for Ollama:
//    {"provider":"ollama","model":"qwen3.5:4b"}
//  The apiKey field is optional and ignored.
//

import Foundation

/// Non-streaming Ollama local vision client.
///
/// Instantiate once and reuse across calls — the shared URLSession with its
/// long timeouts is allocated at init time. This follows the same shared-
/// session pattern documented in AGENTS.md and used in OpenRouterAPI.
class OllamaAPI {

    // MARK: - Constants

    /// The Ollama OpenAI-compatible completions endpoint running on localhost.
    ///
    /// This is the standard Ollama default. If the user runs Ollama on a
    /// non-default port they must change this; for now the default covers
    /// virtually all Ollama installations.
    private static let chatCompletionsURL = URL(string: "http://localhost:11434/v1/chat/completions")!

    /// Dummy Bearer token sent in the Authorization header.
    ///
    /// Ollama ignores this value completely when running locally. We include
    /// it so the request shape is structurally consistent with other providers
    /// and so any HTTP debugging proxy does not flag a missing Authorization
    /// header as anomalous.
    private static let dummyBearerToken = "Bearer ollama"

    /// Token ceiling matching OpenRouterAPI and the streaming Claude path.
    private static let maxTokens = 2048

    // MARK: - Session

    /// Single shared URLSession for all Ollama requests, with long timeouts.
    ///
    /// Why the long timeouts:
    ///   - timeoutIntervalForRequest (180s): the per-read-data timeout. Local
    ///     inference on a cold-started 4.7B model can take 30–90s before the
    ///     first token arrives. The default 60s fires too early.
    ///   - timeoutIntervalForResource (240s): the total request lifetime cap.
    ///     Set higher than the request timeout so a slow-but-steady inference
    ///     run can complete rather than being killed mid-stream.
    ///
    /// Unlike OpenRouterAPI we do NOT enable waitsForConnectivity — if Ollama
    /// is not running we want to fail fast with NSURLErrorCannotConnectToHost
    /// (so we can surface the "is Ollama running?" message) rather than hanging
    /// silently until the network changes.
    private let session: URLSession

    // MARK: - Init

    init() {
        let sessionConfiguration = URLSessionConfiguration.default
        // Long timeouts are mandatory for local LLM inference — see comment above.
        sessionConfiguration.timeoutIntervalForRequest = 180
        sessionConfiguration.timeoutIntervalForResource = 240
        // Do NOT set waitsForConnectivity — we want fast failure when Ollama is offline.
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        self.session = URLSession(configuration: sessionConfiguration)
    }

    // MARK: - Main vision call

    /// Sends a vision request to the local Ollama instance and returns the
    /// model's text response.
    ///
    /// - Parameters:
    ///   - images: Labeled screenshot data. Each image is sent as a base64
    ///     `image_url` part preceded by a text part carrying its label,
    ///     matching the label-before-image ordering used by ClaudeAPI and
    ///     OpenRouterAPI.
    ///   - systemPrompt: Placed as the first message with role "system".
    ///   - conversationHistory: Prior exchange pairs for multi-turn context.
    ///     Encoded as alternating user/assistant text-only messages, matching
    ///     the history encoding used by OpenRouterAPI.
    ///   - userPrompt: The user's current transcript or verification question.
    ///   - supplementalContextText: Optional AX inventory text injected after
    ///     the user prompt, matching ClaudeAPI and OpenRouterAPI behaviour.
    ///     Pass nil when no inventory is available.
    ///   - model: The Ollama model identifier (e.g. "qwen3.5:4b"). This must
    ///     be a model that has already been pulled via `ollama pull <model>`.
    ///
    /// - Returns: The text content of `choices[0].message.content`.
    /// - Throws: A descriptive error on network failure, connection refused,
    ///   timeout, or malformed response. Connection errors produce a user-
    ///   friendly "is Ollama running?" message the caller can speak aloud.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        supplementalContextText: String?,
        model: String
    ) async throws -> String {

        // MARK: Build request

        var urlRequest = URLRequest(url: Self.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        // Mirror the per-request timeout from the session config. URLRequest
        // timeoutInterval is the read-data timeout; the session-level value
        // already covers this, but setting it here too makes the intent
        // explicit and survives any future session reconfiguration.
        urlRequest.timeoutInterval = 180
        // Dummy Bearer token — Ollama ignores it; included for structural consistency.
        urlRequest.setValue(Self.dummyBearerToken, forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Intentionally omitting HTTP-Referer and X-Title — those are OpenRouter-
        // specific attribution headers that Ollama does not recognise.

        // MARK: Build messages array

        var messages: [[String: Any]] = []

        // System message first — Ollama supports the standard system role.
        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        // Conversation history as alternating text-only user/assistant pairs.
        // Images are only in the final turn — same encoding used by OpenRouterAPI.
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Final user message: an array of content parts.
        // Structure: text (prompt + optional supplemental context), then for
        // each image: text label followed by the image_url part.
        var finalUserContentParts: [[String: Any]] = []

        // Combine userPrompt with supplementalContextText (if any) in a single
        // text part — matching how OpenRouterAPI.analyzeImage assembles this.
        let combinedUserText: String
        if let supplementalContextText = supplementalContextText {
            combinedUserText = userPrompt + "\n\n" + supplementalContextText
        } else {
            combinedUserText = userPrompt
        }
        finalUserContentParts.append([
            "type": "text",
            "text": combinedUserText
        ])

        // Each image is preceded by its dimension label so the model knows the
        // pixel coordinate space — mirroring the label-before-image pattern in
        // ClaudeAPI.buildContentBlocks and OpenRouterAPI.analyzeImage.
        for image in images {
            finalUserContentParts.append([
                "type": "text",
                "text": image.label
            ])
            finalUserContentParts.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
                ]
            ])
        }

        messages.append(["role": "user", "content": finalUserContentParts])

        // MARK: Build request body

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "messages": messages
        ]

        let requestBodyData = try JSONSerialization.data(withJSONObject: requestBody)
        urlRequest.httpBody = requestBodyData

        let payloadSizeInMegabytes = Double(requestBodyData.count) / 1_048_576.0
        print("🦙 Ollama request: \(String(format: "%.1f", payloadSizeInMegabytes))MB, \(images.count) image(s), model: \(model)")

        // MARK: Send request

        let (responseData, urlResponse): (Data, URLResponse)
        do {
            (responseData, urlResponse) = try await session.data(for: urlRequest)
        } catch let networkError as NSError {
            // Map common local-server failure codes to a user-friendly message
            // the caller can speak aloud. NSURLErrorCannotConnectToHost fires
            // when Ollama is not running; NSURLErrorTimedOut fires when the
            // model is taking longer than 180s (e.g. very first cold start of
            // a large model on constrained hardware).
            let userFriendlyConnectionErrors: [Int] = [
                NSURLErrorCannotConnectToHost,    // Ollama not running / wrong port (covers ECONNREFUSED)
                NSURLErrorCannotFindHost,         // localhost unresolvable
                NSURLErrorNetworkConnectionLost,  // connection dropped mid-inference
                NSURLErrorTimedOut                // 180s request timeout exceeded
            ]
            if userFriendlyConnectionErrors.contains(networkError.code) {
                throw NSError(
                    domain: "OllamaAPI",
                    code: networkError.code,
                    userInfo: [NSLocalizedDescriptionKey: "Can't reach Ollama at localhost:11434 — is it running? (start with `ollama serve`)"]
                )
            }
            // Re-throw any other network error unchanged.
            throw networkError
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw NSError(
                domain: "OllamaAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama returned a non-HTTP response — this should never happen for a local server"]
            )
        }

        // MARK: Handle non-2xx status codes

        guard (200...299).contains(httpResponse.statusCode) else {
            let rawResponseBody = String(data: responseData, encoding: .utf8) ?? "(unreadable response body)"
            throw NSError(
                domain: "OllamaAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Ollama API error (\(httpResponse.statusCode)): \(rawResponseBody)"]
            )
        }

        // MARK: Parse response

        // Ollama's OpenAI-compat layer returns the same choices[0].message.content
        // structure as OpenRouter. For reasoning models (e.g. qwen3.5:4b) the
        // thinking trace is placed in a separate field; choices[0].message.content
        // contains only the clean final answer with no <think> tags — parse it
        // identically to how OpenRouterAPI parses its response.
        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choicesArray = responseJSON["choices"] as? [[String: Any]],
              let firstChoice = choicesArray.first,
              let messageObject = firstChoice["message"] as? [String: Any],
              let responseText = messageObject["content"] as? String else {
            let rawResponseBody = String(data: responseData, encoding: .utf8) ?? "(unreadable)"
            throw NSError(
                domain: "OllamaAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama returned an unexpected response format: \(rawResponseBody)"]
            )
        }

        return responseText
    }
}
