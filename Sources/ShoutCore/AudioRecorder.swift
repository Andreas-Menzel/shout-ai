// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

@preconcurrency import AVFoundation
import Foundation

/// Captures microphone audio and accumulates it as 16 kHz mono Float32 samples
/// (the input format Whisper expects).
public final class AudioRecorder {
    public static let targetSampleRate: Double = 16000

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()
    public private(set) var isRecording = false

    /// Called on the main actor with a 0...1 input level, roughly 10–25×/second.
    public var onLevel: (@MainActor @Sendable (Float) -> Void)?

    public init() {}

    public func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        // Fresh engine every session so device changes between dictations are picked up.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw ShoutError.noInputDevice
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ShoutError.noInputDevice
        }

        // Capture the converter in the tap closure instead of reading a mutable
        // `self.converter`: the audio thread would otherwise race `stop()` nilling
        // it. `removeTap` stops future invocations; captured, it's never nil here.
        // `onLevel` is captured for the same reason — it's a `var`, and reading it
        // per callback would be an unsynchronised cross-thread read. Fixing the
        // sink for the take also means a mid-take reassignment can't half-apply.
        let levelSink = onLevel
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter, levelSink: levelSink)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
        Log.audio.info("Recording started (\(inFormat.sampleRate, privacy: .public) Hz → 16 kHz)")
    }

    /// Stops capture and returns everything recorded as 16 kHz mono samples.
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false

        lock.lock()
        let result = samples
        samples = []
        lock.unlock()
        Log.audio.info("Recording stopped: \(result.count, privacy: .public) samples (\(Double(result.count) / Self.targetSampleRate, format: .fixed(precision: 2), privacy: .public)s)")
        return result
    }

    public func cancel() {
        _ = stop()
    }

    /// Bounded views of the in-progress take, for live interim transcription.
    public struct Windows: Sendable {
        /// Total samples captured so far — the full length, even though only the
        /// windows below are copied.
        public let totalCount: Int
        /// The first `head` samples requested (or all of them, if fewer).
        public let head: [Float]
        /// The last `tail` samples requested (or all of them, if fewer).
        public let tail: [Float]
    }

    /// Copies just the leading and trailing windows an interim pass needs, read
    /// under a single lock so both describe the same instant. Pass `0` for a
    /// window you don't need.
    ///
    /// Deliberately *not* a whole-buffer snapshot. Handing back `samples` itself
    /// leaves the array multiply-referenced, so the next `append` on the audio
    /// render thread has to copy the entire buffer — up to 19 MB at
    /// `Tuning.maxDictationDuration` — while holding this lock, every 250–600 ms.
    /// Allocating multi-megabyte copies on a real-time audio thread is how you get
    /// dropouts on long hands-free takes. The windows are bounded (20 s each), and
    /// the copies below are freshly allocated, so the recorder's own buffer stays
    /// uniquely referenced and append never copies.
    public func windows(head headCount: Int, tail tailCount: Int) -> Windows {
        lock.lock(); defer { lock.unlock() }
        let total = samples.count
        return samples.withUnsafeBufferPointer { buffer in
            Windows(totalCount: total,
                    head: Self.copy(buffer, count: min(headCount, total), fromEnd: false),
                    tail: Self.copy(buffer, count: min(tailCount, total), fromEnd: true))
        }
    }

    /// Building an `Array` from an `UnsafeBufferPointer` always allocates, which is
    /// the point: an `ArraySlice` would keep the source buffer alive and shared.
    /// Internal rather than private so the window arithmetic can be tested — the
    /// recorder's own buffer can't be populated without a live microphone.
    static func copy(_ buffer: UnsafeBufferPointer<Float>,
                     count: Int, fromEnd: Bool) -> [Float] {
        guard count > 0 else { return [] }
        let start = fromEnd ? buffer.count - count : 0
        return Array(UnsafeBufferPointer(rebasing: buffer[start..<start + count]))
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                         levelSink: (@MainActor @Sendable (Float) -> Void)?) {
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (sum / Float(max(chunk.count, 1))).squareRoot()
        let level = min(1, rms * Tuning.audioLevelGain)
        // Deliver on the main actor. The closure carries only the sink and a
        // Float, so nothing non-Sendable crosses the hop.
        guard let levelSink else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { levelSink(level) } }
    }
}
