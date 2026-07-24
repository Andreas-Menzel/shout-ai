// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

@preconcurrency import AVFoundation
import Foundation

/// Loads any audio file AVFoundation can read and converts it to 16 kHz mono
/// Float32 samples. Used by the CLI test harness.
public enum AudioFileLoader {
    public static func loadSamples16k(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ShoutError.audioFileUnreadable(url.path)
        }

        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw ShoutError.audioFileUnreadable(url.path)
        }
        try file.read(into: inBuffer)

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ShoutError.audioFileUnreadable(url.path)
        }

        let ratio = AudioRecorder.targetSampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw ShoutError.audioFileUnreadable(url.path)
        }

        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, let channel = outBuffer.floatChannelData else {
            throw ShoutError.audioFileUnreadable(url.path)
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
    }
}
