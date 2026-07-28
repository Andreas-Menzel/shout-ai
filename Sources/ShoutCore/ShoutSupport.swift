// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import os

public enum Log {
    public static let app = Logger(subsystem: "de.menzelini.shout", category: "app")
    public static let audio = Logger(subsystem: "de.menzelini.shout", category: "audio")
    public static let whisper = Logger(subsystem: "de.menzelini.shout", category: "whisper")
    public static let rewrite = Logger(subsystem: "de.menzelini.shout", category: "rewrite")
    public static let model = Logger(subsystem: "de.menzelini.shout", category: "model")
}

public enum ShoutPaths {
    public static var appSupportDir: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var modelsDir: URL {
        let dir = appSupportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum ShoutError: LocalizedError, Equatable {
    case noInputDevice
    case modelNotLoaded
    case modelLoadFailed(String)
    case modelDownloadIncomplete
    case transcriptionFailed(Int)
    case rewriteUnavailable
    case endpointNotConfigured
    case endpointInsecureHTTP
    case endpointBadStatus(Int)
    case endpointEmptyResponse
    case timeout
    case audioFileUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device found"
        case .modelNotLoaded: return "Speech model is not loaded"
        case .modelLoadFailed(let path): return "Could not load speech model at \(path)"
        case .modelDownloadIncomplete: return "The model download was incomplete — please try again"
        case .transcriptionFailed(let code): return "Transcription failed (code \(code))"
        case .rewriteUnavailable: return "Apple Intelligence model unavailable"
        case .endpointNotConfigured: return "This endpoint has no server URL or model set"
        case .endpointInsecureHTTP: return "Insecure HTTP to a remote server is turned off — enable it in the endpoint’s settings, or use HTTPS"
        case .endpointBadStatus(let code): return "The endpoint returned HTTP \(code)"
        case .endpointEmptyResponse: return "The endpoint returned no usable text"
        case .timeout: return "Operation timed out"
        case .audioFileUnreadable(let path): return "Could not read audio file \(path)"
        }
    }
}

/// Language selection for transcription.
public enum LanguageMode: String, CaseIterable, Codable, Sendable {
    case auto
    case german = "de"
    case english = "en"

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect (German / English)"
        case .german: return "German"
        case .english: return "English"
        }
    }
}

public func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
}

/// Runs `operation`, but gives up and throws `ShoutError.timeout` once `seconds`
/// elapse. This is a *hard* deadline: a plain task-group race awaits every child
/// at scope exit, so an operation that never observes cancellation would still
/// block past the deadline. Here the operation runs in an unstructured task that
/// is cancelled and then abandoned — the call returns the moment the timer wins,
/// regardless of whether the operation cooperates. Also honors cancellation of
/// the surrounding task.
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = TimeoutGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            gate.attach(continuation)
            let work = Task {
                do { gate.resolve(.success(try await operation())) }
                catch { gate.resolve(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.resolve(.failure(ShoutError.timeout))
            }
            gate.track(work: work, timer: timer)
        }
    } onCancel: {
        gate.resolve(.failure(CancellationError()))
    }
}

/// Resumes a continuation exactly once and tears down the racing tasks. Thread
/// safe: the timer, the operation, and an outer cancellation can all race to
/// resolve; the first wins and the rest are no-ops.
private final class TimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var resolved = false

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func track(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        self.work = work
        self.timer = timer
        let alreadyResolved = resolved
        lock.unlock()
        if alreadyResolved { work.cancel(); timer.cancel() }
    }

    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        if resolved { lock.unlock(); return }
        resolved = true
        let continuation = self.continuation
        let work = self.work
        let timer = self.timer
        self.continuation = nil
        lock.unlock()

        work?.cancel()
        timer?.cancel()
        switch result {
        case .success(let value): continuation?.resume(returning: value)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}
