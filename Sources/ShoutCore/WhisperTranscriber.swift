// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import whisper

/// whisper.cpp-backed `TranscriptionEngine`. Thread-safe: all C-context access
/// is serialized on a private queue; the model stays resident once loaded. The
/// engine owns its model file URL, so callers never thread a path through it.
public final class WhisperTranscriber: TranscriptionEngine, @unchecked Sendable {
    private let modelURL: URL
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "com.shoutai.whisper", qos: .userInitiated)

    /// Load-state readable without touching `queue` — reading it must never block
    /// the caller (the main actor asks this on the hot path). A `queue.sync`
    /// accessor here would stall the UI for the length of an in-flight load or
    /// transcription.
    private let readyLock = NSLock()
    private var _isReady = false

    /// Route whisper.cpp / ggml C-level logging into os_log once per process
    /// instead of letting it flood stderr.
    private static let installLogHandler: Void = {
        whisper_log_set({ level, text, _ in
            guard let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            if level == GGML_LOG_LEVEL_ERROR {
                Log.whisper.error("\(message, privacy: .public)")
            } else {
                Log.whisper.debug("\(message, privacy: .public)")
            }
        }, nil)
    }()

    public init(modelURL: URL) {
        self.modelURL = modelURL
        _ = Self.installLogHandler
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    public var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }
        return _isReady
    }

    private func setReady(_ value: Bool) {
        readyLock.lock(); _isReady = value; readyLock.unlock()
    }

    /// Loads the model from disk (a few seconds for large-v3-turbo). Safe to call
    /// repeatedly; a no-op once loaded.
    public func prepare() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.loadOnQueue(); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Must run on `queue`.
    private func loadOnQueue() throws {
        guard ctx == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ShoutError.modelLoadFailed(modelURL.path)
        }
        var params = whisper_context_default_params()
        params.use_gpu = true
        let started = Date()
        guard let context = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw ShoutError.modelLoadFailed(modelURL.path)
        }
        ctx = context
        setReady(true)
        Log.whisper.info("Model loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")
    }

    /// Transcribes 16 kHz mono samples. `glossary` biases recognition toward custom terms.
    public func transcribe(
        samples: [Float],
        language: LanguageMode,
        glossary: [String]
    ) async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try self.transcribeLocked(
                        samples: samples, language: language, glossary: glossary))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func transcribeLocked(
        samples: [Float],
        language: LanguageMode,
        glossary: [String]
    ) throws -> TranscriptionResult {
        guard let ctx else { throw ShoutError.modelNotLoaded }

        // Skip near-silent audio: Whisper hallucinates on it ("Thanks for watching!").
        var sum: Float = 0
        for v in samples { sum += v * v }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        guard rms > Tuning.silenceRMSThreshold else {
            Log.whisper.info("Audio below silence threshold (rms \(rms, privacy: .public)); skipping")
            return TranscriptionResult(text: "", languageCode: language == .german ? "de" : "en")
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.translate = false
        params.no_context = true
        params.suppress_blank = true
        params.n_threads = Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let langCString = strdup(language.rawValue) // "auto" | "de" | "en"
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)

        var promptCString: UnsafeMutablePointer<CChar>?
        if !glossary.isEmpty {
            let prompt = "Glossary: " + glossary.joined(separator: ", ") + "."
            promptCString = strdup(String(prompt.prefix(Tuning.whisperGlossaryPromptCap)))
            params.initial_prompt = UnsafePointer(promptCString)
        }
        defer { if let promptCString { free(promptCString) } }

        let started = Date()
        let status = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard status == 0 else { throw ShoutError.transcriptionFailed(Int(status)) }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        let langId = whisper_full_lang_id(ctx)
        let code = langId >= 0 ? String(cString: whisper_lang_str(langId)) : "en"
        var cleaned = Self.tidy(text)
        if Self.hallucinations.contains(cleaned.lowercased()) {
            Log.whisper.info("Dropped hallucinated transcript: \(cleaned, privacy: .public)")
            cleaned = ""
        }
        Log.whisper.info("Transcribed \(Double(samples.count) / AudioRecorder.targetSampleRate, format: .fixed(precision: 1), privacy: .public)s audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s (lang=\(code, privacy: .public))")
        return TranscriptionResult(text: cleaned, languageCode: code)
    }

    /// Phrases Whisper invents on silence or breath noise; dropped when they
    /// are the entire transcript.
    static let hallucinations: Set<String> = [
        "you", "bye.", "thank you.", "thanks for watching!", "thanks for watching.",
        "vielen dank.", "tschüss.", "untertitel im auftrag des zdf für funk, 2017",
        "untertitelung des zdf, 2020", "das war's. bis zum nächsten mal.",
    ]

    /// Removes whisper noise artifacts like "[BLANK_AUDIO]", "(Musik)", "♪".
    static func tidy(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"♪+"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
