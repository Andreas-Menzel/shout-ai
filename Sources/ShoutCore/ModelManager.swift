// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import CryptoKit
import Foundation
import Observation

/// Describes a downloadable Whisper model. Adding a new size/variant is data,
/// not code: append a spec and it becomes selectable.
public struct WhisperModelSpec: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let fileName: String
    public let url: URL
    /// Exact byte size of the official file. Checked for equality, not as a
    /// floor: a download truncated in its final stretch is still large enough to
    /// look plausible, and treating it as complete would fail every later
    /// transcription with no signal about why.
    public let expectedBytes: Int64
    /// Optional lowercase hex SHA-256. When set, a freshly downloaded file is
    /// verified against it before use, closing the supply-chain gap. Left nil
    /// until a hash is pinned for the release.
    public let sha256: String?

    public init(id: String, displayName: String, fileName: String, url: URL,
                expectedBytes: Int64, sha256: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.url = url
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
    }

    public static let largeV3Turbo = WhisperModelSpec(
        id: "large-v3-turbo",
        displayName: "Large v3 Turbo — multilingual, ~1.6 GB",
        fileName: "ggml-large-v3-turbo.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        expectedBytes: 1_624_555_275,
        // SHA-256 of the official ggml-large-v3-turbo.bin. Pinned so a freshly
        // downloaded file is verified before it's ever loaded by native ggml —
        // a tampered or truncated download fails closed. This model is a stable,
        // versioned artifact, so the pin is one-time: a genuinely new model would
        // ship in a Shout update with its new hash (the app never silently
        // accepts a changed model file).
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")

    public static let all: [WhisperModelSpec] = [.largeV3Turbo]
}

/// Tracks and downloads the Whisper model file for a given spec.
@Observable
public final class ModelManager {
    public enum State: Equatable {
        case missing
        case downloading(Double) // 0...1
        case ready
        case failed(String)
    }

    public let spec: WhisperModelSpec
    public var state: State = .missing

    @ObservationIgnored private var delegateBox: DownloadDelegate?

    public var modelPath: URL {
        ShoutPaths.modelsDir.appendingPathComponent(spec.fileName)
    }

    public init(spec: WhisperModelSpec = .largeV3Turbo) {
        self.spec = spec
        refresh()
    }

    public func refresh() {
        if case .downloading = state { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        // Exact size, so a partial download is reported missing (and re-fetched)
        // rather than loaded. The SHA-256 pin is enforced on the download itself
        // — see DownloadDelegate — since re-hashing 1.6 GB on every launch would
        // stall startup for seconds.
        if size == spec.expectedBytes {
            state = .ready
        } else if case .failed = state {
            // keep the error visible until the next download attempt
        } else {
            state = .missing
        }
    }

    @MainActor
    public func startDownload() {
        if case .downloading = state { return }
        if case .ready = state { return }
        state = .downloading(0)
        Log.model.info("Starting model download")

        let delegate = DownloadDelegate(
            destination: modelPath,
            expectedBytes: spec.expectedBytes,
            sha256: spec.sha256,
            onProgress: { [weak self] p in self?.state = .downloading(p) },
            onFinish: { [weak self] result in
                switch result {
                case .success:
                    self?.state = .ready
                    Log.model.info("Model download complete")
                case .failure(let error):
                    self?.state = .failed(error.localizedDescription)
                    Log.model.error("Model download failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.delegateBox = nil
            }
        )
        delegateBox = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        session.downloadTask(with: spec.url).resume()
    }
}

// URLSession requires a Sendable delegate. Every callback is delivered on
// `delegateQueue: .main` (see startDownload), so the stored closures — which
// hop back into the main-actor ModelManager — are only ever touched on the
// main thread. That invariant is what makes the unchecked conformance safe.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expectedBytes: Int64
    let sha256: String?
    let onProgress: (Double) -> Void
    let onFinish: (Result<Void, Error>) -> Void

    init(destination: URL, expectedBytes: Int64, sha256: String?,
         onProgress: @escaping (Double) -> Void,
         onFinish: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        defer { session.finishTasksAndInvalidate() }
        do {
            // Validate BEFORE committing: a dropped connection or an HTML error
            // body still fires this callback, and marking a truncated file
            // "ready" would fail every later transcription with no signal.
            let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int64) ?? 0
            guard size == expectedBytes else {
                try? FileManager.default.removeItem(at: location)
                onFinish(.failure(ShoutError.modelDownloadIncomplete))
                return
            }
            if let expected = sha256, Self.sha256Hex(of: location)?.caseInsensitiveCompare(expected) != .orderedSame {
                try? FileManager.default.removeItem(at: location)
                onFinish(.failure(ShoutError.modelDownloadIncomplete))
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish(.success(()))
        } catch {
            onFinish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinish(.failure(error))
            session.finishTasksAndInvalidate()
        }
    }

    /// Streams the file so a 1.6 GB model isn't loaded into memory to hash it.
    private static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
