// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// `RewriteEngine` backed by any OpenAI-compatible chat-completions endpoint —
/// a local Ollama / LM Studio server or a remote one. Runs the profile-built
/// prompt and returns the model's raw text; prompt assembly and guards live in
/// the shared `rewrite(profile:…)`. The caller falls back to the raw transcript
/// on any error, so an unreachable or slow endpoint never loses the words.
///
/// Responses are streamed so a slow-but-generating server (a big reasoning
/// model at a dozen tokens/s) is distinguishable from a dead one: arriving
/// chunks keep resetting the idle timeout, while the total wait is bounded by
/// `rewriteDeadline` instead of the on-device ceiling.
///
/// The transcript text (never the audio) is what leaves the machine when the
/// endpoint is non-loopback — see `ModelEntry.isLocal`.
public final class EndpointRewriter: RewriteEngine, Sendable {
    private let config: EndpointConfig
    private let apiKey: String?
    /// Whether a remote `http` (clear-text) endpoint is permitted. The policy
    /// lives in the app (`SettingsStore.allowInsecureHTTP`, off by default) and
    /// is passed in; defaults permissive so ShoutCore stays policy-free for
    /// tests and the CLI, while the app enforces the opt-in.
    private let allowInsecureHTTP: Bool
    private let session: URLSession

    /// - Parameter session: injected so tests can stub the network with a
    ///   `URLProtocol`; production uses `.shared`.
    public init(config: EndpointConfig, apiKey: String? = nil,
                allowInsecureHTTP: Bool = true, session: URLSession = .shared) {
        self.config = config
        self.apiKey = apiKey
        self.allowInsecureHTTP = allowInsecureHTTP
        self.session = session
    }

    public var availability: EngineAvailability {
        // Reachability can't be probed cheaply/synchronously, so this only
        // reflects whether the endpoint is configured; a down server surfaces as
        // a thrown error at rewrite time (→ raw fallback) or via "Test connection".
        guard config.isConfigured else {
            return .unavailable("Set a server URL and model for this endpoint")
        }
        // A remote clear-text endpoint stays unavailable until the user opts in,
        // so the pipeline falls back to raw and Settings shows the reason.
        if config.isInsecureRemote, !allowInsecureHTTP {
            return .unavailable("Insecure HTTP to a remote server is off — enable it in the endpoint’s settings, or use HTTPS")
        }
        return .available
    }

    /// Endpoint models have large contexts, so don't impose the on-device cap.
    public var maxInputCharacters: Int { .max }

    /// Endpoint models may be slow while streaming keeps proving they're alive
    /// (a 32B reasoning model can take a minute); the idle timeout in
    /// `complete` still catches dead servers within `Tuning.rewriteTimeout`.
    public var rewriteDeadline: TimeInterval { Tuning.endpointRewriteTimeout }

    /// Endpoints keep no resident session to warm.
    public func prewarm(instructions: String) {}

    /// A minimal round-trip used by the Settings "Test connection" button.
    /// Returns the model's reply on success; throws a descriptive `ShoutError`
    /// (or `URLError`) on any failure.
    public func testConnection() async throws -> String {
        try await complete(
            system: "You are a connection test. Reply with a short greeting.",
            user: "Say hello.")
    }

    public func complete(system: String, user: String) async throws -> String {
        guard config.isConfigured else { throw ShoutError.endpointNotConfigured }
        // Refuse to put the API key + transcript on the wire in clear text to a
        // remote host unless the user explicitly allowed it.
        guard allowInsecureHTTP || !config.isInsecureRemote else { throw ShoutError.endpointInsecureHTTP }

        var request = URLRequest(url: config.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            Self.requestBody(model: config.model, reasoningEffort: config.reasoningEffort,
                             system: system, user: user))
        // An IDLE timeout, not a total budget: the response streams, so every
        // arriving chunk resets it. A dead server still fails fast (→ raw
        // fallback) while a slow model that is visibly generating gets to run
        // until the pipeline's `rewriteDeadline`.
        request.timeoutInterval = Tuning.rewriteTimeout

        let started = Date()
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ShoutError.endpointBadStatus(http.statusCode)
        }
        var assembler = StreamAssembler()
        for try await line in bytes.lines {
            if assembler.consume(line) { break }
        }
        Log.rewrite.info("Endpoint rewrite took \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")

        guard let content = assembler.content else {
            throw ShoutError.endpointEmptyResponse
        }
        return content
    }

    // MARK: - Wire format (pure, testable)

    struct RequestBody: Encodable, Equatable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        /// Omitted from the JSON entirely when nil (synthesized encodeIfPresent),
        /// so servers that reject unknown fields only ever see it by user choice.
        let reasoningEffort: ReasoningEffort?
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
            case reasoningEffort = "reasoning_effort"
        }

        struct Message: Encodable, Equatable {
            let role: String
            let content: String
        }
    }

    static func requestBody(model: String, reasoningEffort: ReasoningEffort? = nil,
                            system: String, user: String) -> RequestBody {
        RequestBody(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: 0,
            maxTokens: Tuning.endpointMaxTokens,
            reasoningEffort: reasoningEffort,
            stream: true)
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        let choices: [Choice]
    }

    /// Assembles the assistant text from a streamed chat-completions response,
    /// one `data:` SSE line at a time. Only `delta.content` is ever read — the
    /// thinking a server splits into `reasoning`/`reasoning_content` deltas
    /// can't reach the document. Also tolerates a server that ignores
    /// `stream: true`: when no SSE lines arrive, the collected body is parsed
    /// as a single non-streamed JSON response instead.
    struct StreamAssembler {
        private var streamed = ""
        private var plainBody = ""
        private var sawSSE = false

        /// Feed one response line; returns true once the stream signalled
        /// completion (`[DONE]`), after which the caller can stop reading.
        mutating func consume(_ line: String) -> Bool {
            guard line.hasPrefix("data:") else {
                if !sawSSE { plainBody += line }
                return false
            }
            sawSSE = true
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return true }
            if let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)),
               let delta = chunk.choices.first?.delta?.content {
                streamed += delta
            }
            return false
        }

        /// The cleaned final text, nil when nothing usable arrived (the caller
        /// then throws `endpointEmptyResponse`).
        var content: String? {
            sawSSE ? EndpointRewriter.cleanContent(streamed)
                   : EndpointRewriter.parseContent(Data(plainBody.utf8))
        }

        private struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
            }
            let choices: [Choice]
        }
    }

    /// Extracts the assistant text from a non-streamed OpenAI-shaped response —
    /// the fallback for servers that ignore `stream: true`. Returns nil when
    /// the body is malformed or carries no usable content.
    static func parseContent(_ data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = decoded.choices.first?.message?.content else { return nil }
        return cleanContent(content)
    }

    /// Shared final cleanup for streamed and non-streamed content. Some servers
    /// leave a reasoning model's chain-of-thought inline as `<think>…</think>`
    /// instead of splitting it out. Those blocks — including one left
    /// unterminated by a response cap — are stripped before the empty-check, so
    /// thoughts are never pasted into the user's document and a think-only
    /// reply falls back to raw.
    static func cleanContent(_ content: String) -> String? {
        let stripped = content.replacingOccurrences(
            of: "(?s)<think>.*?(</think>|$)", with: "", options: .regularExpression)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
