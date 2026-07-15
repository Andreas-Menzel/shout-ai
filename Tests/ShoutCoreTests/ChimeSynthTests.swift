// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

/// The synthesized cue pair: one voice, mirrored contours, click-free and
/// short — properties the app relies on rather than the exact waveform.
final class ChimeSynthTests: XCTestCase {
    private let voices = [ChimeSynth.strikeVoice, ChimeSynth.glassVoice]

    func testShippedCuesAreShort() {
        for wav in [ChimeSynth.promptWAV(), ChimeSynth.latchWAV()] {
            let seconds = Double((wav.count - 44) / 2) / ChimeSynth.sampleRate
            XCTAssertGreaterThan(seconds, 0.2, "long enough to register")
            XCTAssertLessThan(seconds, 0.5, "short enough not to intrude")
        }
    }

    func testPeakIsModerateAndNeverClips() {
        for voice in voices {
            let mix = ChimeSynth.pair(ChimeSynth.lowNote, ChimeSynth.highNote, voice: voice)
            let peak = mix.map(abs).max() ?? 0
            XCTAssertEqual(peak, 0.4, accuracy: 0.001, "normalized to the designed level")
        }
    }

    func testEndsFadedToSilenceSoPlaybackCannotClick() {
        for voice in voices {
            let samples = ChimeSynth.pair(ChimeSynth.highNote, ChimeSynth.lowNote, voice: voice)
            XCTAssertEqual(samples.last, 0, "hard zero at the very end")
            let tail = samples.suffix(64).map(abs).max() ?? 1
            XCTAssertLessThan(tail, 0.02)
        }
    }

    func testStartsFromSilenceSoPlaybackCannotClick() {
        for voice in voices {
            let first = ChimeSynth.note(ChimeSynth.highNote, voice: voice).first ?? 1
            XCTAssertEqual(first, 0, "attack ramp starts at zero")
        }
    }

    func testPromptAndLatchAreMirroredNotIdentical() {
        XCTAssertNotEqual(ChimeSynth.promptWAV(), ChimeSynth.latchWAV())
        XCTAssertEqual(ChimeSynth.promptWAV().count, ChimeSynth.latchWAV().count,
                       "same figure, opposite direction")
    }

    func testWAVIsWellFormedForAVAudioPlayer() {
        let data = ChimeSynth.promptWAV()
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        let riffSize = data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), data.count - 8, "declared size matches the payload")
    }

    func testDeterministicAcrossBuilds() {
        XCTAssertEqual(ChimeSynth.promptWAV(), ChimeSynth.promptWAV(),
                       "fixed noise seed — auditioned files match shipped sound")
    }
}
