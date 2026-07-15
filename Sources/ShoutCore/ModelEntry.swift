// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// A rewrite model the app can use, as shown in the model picker. The registry
/// synthesizes the always-present on-device Apple entry and persists the user's
/// endpoint (and, later, local-file) entries. Profiles reference an entry by its
/// `id` (`Profile.modelID`).
public struct ModelEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var kind: Kind

    public init(id: String, displayName: String, kind: Kind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }

    public enum Kind: Codable, Equatable, Sendable {
        /// The on-device Apple Intelligence model — zero download, private.
        case appleFoundation
        /// An OpenAI-compatible chat-completions endpoint (local or remote).
        case endpoint(EndpointConfig)
    }

    /// True when running this model keeps the transcript on this Mac: only the
    /// on-device model and a loopback endpoint qualify. Any other host (LAN or
    /// remote) means the transcript text leaves the machine. Drives the privacy
    /// label and the pill's non-local indicator.
    public var isLocal: Bool {
        switch kind {
        case .appleFoundation: return true
        case .endpoint(let config): return config.isLoopback
        }
    }

    /// Stable id of the built-in on-device entry.
    public static let appleFoundationID = "apple-foundation"

    public static let appleFoundation = ModelEntry(
        id: appleFoundationID,
        displayName: "Apple Intelligence (on-device)",
        kind: .appleFoundation)
}

/// How hard a thinking model may reason before answering, sent on the wire as
/// OpenAI's `reasoning_effort` (the raw value). Support varies by server:
/// Ollama honors it on /v1/chat/completions ("none" disables thinking), OpenAI
/// models accept model-dependent subsets, LM Studio currently ignores it (its
/// per-model server setting wins), and llama.cpp wants `chat_template_kwargs`
/// instead. Servers that don't know the field skip it silently, so sending it
/// is safe — but it is only ever sent when the user set it explicitly.
///
/// The disabled case is named `off`, not `none`: on a `ReasoningEffort?`
/// property, `.none` would resolve to `Optional.none` at every assignment.
public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case off = "none"
    case low
    case medium
    case high
}

/// Connection details for an OpenAI-compatible chat-completions endpoint.
///
/// The API key is deliberately NOT stored here: it lives in the Keychain keyed
/// by the owning entry's id, so secrets never touch UserDefaults. The engine is
/// handed the resolved key at construction.
public struct EndpointConfig: Codable, Equatable, Sendable {
    /// Base URL up to (not including) `/chat/completions`, e.g.
    /// `http://localhost:11434/v1` for Ollama.
    public var baseURL: URL
    /// Model name the server expects, e.g. `qwen3:4b`.
    public var model: String
    /// Reasoning budget to request, or nil (the default) to send nothing and
    /// let the server decide. An explicit user choice in the endpoint editor —
    /// never inferred from the model name.
    public var reasoningEffort: ReasoningEffort?

    public init(baseURL: URL, model: String, reasoningEffort: ReasoningEffort? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    /// The full chat-completions URL. Tolerant of a base that already includes
    /// the path, so both `.../v1` and `.../v1/chat/completions` work.
    public var chatCompletionsURL: URL {
        if baseURL.path.hasSuffix("chat/completions") { return baseURL }
        return baseURL.appendingPathComponent("chat/completions")
    }

    /// True when the host is loopback (this Mac), for the privacy label. A LAN
    /// or public host is treated as leaving the machine.
    public var isLoopback: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// True when using this endpoint would send the transcript (and any API key)
    /// in clear text to a host that isn't this Mac: a remote server reached over
    /// plain `http`. Loopback `http` (a local Ollama/LM Studio) never leaves the
    /// machine, and `https` is encrypted — only remote `http` is exposed. Gated
    /// behind an explicit user opt-in; see `SettingsStore.allowInsecureHTTP`.
    public var isInsecureRemote: Bool {
        !isLoopback && baseURL.scheme == "http"
    }

    /// Whether this config is complete enough to attempt a request.
    public var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty
            && (baseURL.scheme == "http" || baseURL.scheme == "https")
            && (baseURL.host?.isEmpty == false)
    }
}
