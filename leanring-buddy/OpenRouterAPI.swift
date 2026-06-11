//
//  OpenRouterAPI.swift
//  leanring-buddy
//
//  Non-streaming OpenRouter chat-completions client for vision requests.
//
//  OpenRouter uses the same OpenAI-compatible /v1/chat/completions endpoint,
//  so the JSON body shape mirrors OpenAIAPI.swift. The key differences are:
//    - Authorization header carries the user's sk-or-... key (read from
//      ~/Library/Application Support/Clicky/llm.json at runtime — never
//      shipped in the binary).
//    - Two extra headers required by OpenRouter's attribution policy:
//        HTTP-Referer: https://github.com/TJ-90/randomclicky
//        X-Title: Clicky
//    - Message history is text-only (same as ClaudeAPI history encoding).
//    - The final user message carries an ARRAY content with text+image_url
//      parts (OpenAI multimodal format) — labels precede each image.
//    - max_tokens is capped at 2048, matching the streaming Claude path.
//

import Foundation

/// Non-streaming OpenRouter vision client.
///
/// Instantiate once and reuse across calls — the shared URLSession is
/// allocated at init time to avoid repeated TLS handshakes (the same
/// AGENTS.md lesson that led to the shared-session pattern in
/// AssemblyAIStreamingTranscriptionProvider).
class OpenRouterAPI {

    // MARK: - Constants

    private static let chatCompletionsURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// HTTP-Referer value required by OpenRouter for attribution.
    private static let httpRefererValue = "https://github.com/TJ-90/randomclicky"

    /// X-Title value shown in the OpenRouter dashboard for this app.
    private static let xTitleValue = "Clicky"

    /// Token ceiling matching the streaming Claude path (2048 gives comfortable
    /// headroom for multi-annotation + walkthrough responses).
    private static let maxTokens = 2048

    // MARK: - Session

    /// Single shared URLSession for all OpenRouter requests.
    ///
    /// Using .default (not .ephemeral) so TLS session tickets are cached and
    /// the first real API call (which carries a large image payload) does not
    /// need a cold TLS handshake. URL/cookie caching is disabled to avoid
    /// storing responses or credentials on disk — we only want the TLS benefit.
    private let session: URLSession

    // MARK: - Init

    init() {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 120
        sessionConfiguration.timeoutIntervalForResource = 300
        sessionConfiguration.waitsForConnectivity = true
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        self.session = URLSession(configuration: sessionConfiguration)

        // Pre-warm the TLS connection to the OpenRouter host so the first
        // real request (which carries one or more JPEG images) skips the
        // cold handshake. Failures are silently ignored — this is a perf
        // optimisation only.
        warmUpTLSConnection()
    }

    // MARK: - TLS warm-up

    /// Fires a lightweight HEAD request to the OpenRouter host to establish
    /// and cache a TLS session ticket. Failures are silently swallowed.
    private func warmUpTLSConnection() {
        var warmupRequest = URLRequest(url: Self.chatCompletionsURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response content is irrelevant — the TLS handshake is the goal.
        }.resume()
    }

    // MARK: - Main vision call

    /// Sends a vision request to OpenRouter and returns the model's text response.
    ///
    /// - Parameters:
    ///   - images: Labeled screenshot data. Each image is sent as a base64
    ///     `image_url` part preceded by a text part carrying its label, matching
    ///     the label-before-image ordering used by ClaudeAPI.buildContentBlocks.
    ///   - systemPrompt: Placed as the first message with role "system".
    ///   - conversationHistory: Prior exchange pairs for multi-turn context.
    ///     Encoded as alternating user/assistant text-only messages — the same
    ///     encoding ClaudeAPI uses for history (images are only in the final turn).
    ///   - userPrompt: The user's current transcript or verification question.
    ///   - supplementalContextText: Optional AX inventory text injected after the
    ///     user prompt in the final user message, matching ClaudeAPI behaviour.
    ///     Pass nil when no inventory is available.
    ///   - apiKey: The sk-or-... key read from the local config file at runtime.
    ///   - model: The OpenRouter model identifier (e.g. "google/gemma-4-26b-a4b-it:free").
    ///
    /// - Returns: The text content of `choices[0].message.content`.
    /// - Throws: A descriptive error on non-2xx status, network failure, or
    ///   malformed response. HTTP 429 produces a user-friendly message that
    ///   the caller can speak aloud without modification.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        supplementalContextText: String?,
        apiKey: String,
        model: String
    ) async throws -> String {

        // MARK: Build request

        var urlRequest = URLRequest(url: Self.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OpenRouter requires these two headers for attribution / dashboard display.
        urlRequest.setValue(Self.httpRefererValue, forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue(Self.xTitleValue, forHTTPHeaderField: "X-Title")

        // MARK: Build messages array

        var messages: [[String: Any]] = []

        // System message first — OpenRouter supports the standard system role.
        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        // Conversation history as alternating text-only user/assistant pairs.
        // Images are not re-sent for previous turns — only the current turn
        // carries image data, matching how ClaudeAPI encodes history.
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Final user message: an array of content parts.
        // Structure: text (prompt + optional supplemental context), then for
        // each image: text label followed by the image_url part.
        var finalUserContentParts: [[String: Any]] = []

        // Combine userPrompt with supplementalContextText (if any) in a single
        // text part — matching how ClaudeAPI.buildContentBlocks appends the
        // supplemental block right before the user prompt text.
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
        // ClaudeAPI.buildContentBlocks.
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
        print("🌐 OpenRouter request: \(String(format: "%.1f", payloadSizeInMegabytes))MB, \(images.count) image(s), model: \(model)")

        // MARK: Send request

        let (responseData, urlResponse) = try await session.data(for: urlRequest)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenRouterAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter returned a non-HTTP response — this should never happen"]
            )
        }

        // MARK: Handle non-2xx status codes

        guard (200...299).contains(httpResponse.statusCode) else {
            let rawResponseBody = String(data: responseData, encoding: .utf8) ?? "(unreadable response body)"

            // HTTP 429 means the free-tier model hit its rate limit. Surface a
            // user-friendly message so the caller can speak it directly without
            // wrapping in technical jargon.
            if httpResponse.statusCode == 429 {
                throw NSError(
                    domain: "OpenRouterAPI",
                    code: 429,
                    userInfo: [NSLocalizedDescriptionKey: "The free model is rate-limited right now — try again in a moment."]
                )
            }

            throw NSError(
                domain: "OpenRouterAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter API error (\(httpResponse.statusCode)): \(rawResponseBody)"]
            )
        }

        // MARK: Parse response

        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choicesArray = responseJSON["choices"] as? [[String: Any]],
              let firstChoice = choicesArray.first,
              let messageObject = firstChoice["message"] as? [String: Any],
              let responseText = messageObject["content"] as? String else {
            let rawResponseBody = String(data: responseData, encoding: .utf8) ?? "(unreadable)"
            throw NSError(
                domain: "OpenRouterAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter returned an unexpected response format: \(rawResponseBody)"]
            )
        }

        return responseText
    }
}
