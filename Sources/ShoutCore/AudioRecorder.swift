// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AVFoundation
import Foundation

/// Captures microphone audio and accumulates it as 16 kHz mono Float32 samples
/// (the input format Whisper expects).
public final class AudioRecorder {
    public static let targetSampleRate: Double = 16000

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()
    public private(set) var isRecording = false

    /// Called on the main queue with a 0...1 input level, roughly 10–25×/second.
    public var onLevel: ((Float) -> Void)?

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
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
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

    /// A thread-safe copy of the audio captured so far, without stopping
    /// capture. Used for live interim transcription while recording continues.
    public func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
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
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}
