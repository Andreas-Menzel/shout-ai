// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// The paired voice-switch cues, synthesized as one instrument so they are
/// audibly siblings — the same struck voice playing mirrored two-note
/// figures. A rising fourth asks ("list is open, your turn"), the same
/// stroke falling answers ("profile locked in"): the shared timbre says the
/// two sounds are about the same thing, the contour says which moment this
/// is. System sounds can't provide that relationship — no two of them share
/// a voice.
///
/// What keeps this from sounding like an alarm-clock beep: the partials are
/// slightly detuned from pure integers (a static waveform reads as
/// electronic), the upper partials decay faster than the fundamental (the
/// signature of a physically struck object), and a few milliseconds of
/// filtered noise mark the contact itself.
///
/// Pure sample/WAV generation only; playback (and its AVFoundation
/// dependency) stays in the app layer.
public enum ChimeSynth {
    public static let sampleRate = 44_100.0

    /// One synthesized instrument: struck partials plus a soft contact
    /// transient, each partial ringing out on its own clock.
    struct Voice {
        /// (frequency ratio, relative amplitude, decay time constant).
        let partials: [(ratio: Double, amplitude: Double, decay: Double)]
        /// Amplitude and decay of the brief noise "contact" at the strike.
        let strike: Double
        let strikeDecay: Double
        /// How long one stroke rings before the next figure/fade.
        let ring: Double
    }

    /// The shipped voice: warm and wooden, fast-decaying — a small marimba
    /// bar rather than a doorbell.
    static let strikeVoice = Voice(
        partials: [(1.0, 1.0, 0.085), (2.004, 0.35, 0.045),
                   (3.01, 0.18, 0.028), (5.4, 0.06, 0.015)],
        strike: 0.12, strikeDecay: 0.006, ring: 0.2)

    /// Auditionable alternative: glassy inharmonic shimmer with a longer
    /// ring. To ship it instead, use this as the voice in
    /// `promptWAV`/`latchWAV`.
    static let glassVoice = Voice(
        partials: [(1.0, 1.0, 0.16), (2.32, 0.30, 0.09),
                   (4.05, 0.14, 0.05), (6.8, 0.05, 0.03)],
        strike: 0.05, strikeDecay: 0.004, ring: 0.32)

    /// D5 and G5: a perfect fourth — wide enough that rising vs falling is
    /// unmistakable — pitched low enough to stay warm on laptop speakers.
    static let lowNote = 587.33
    static let highNote = 784.0
    /// The second stroke lands while the first still rings, like one mallet
    /// hand playing two bars.
    private static let secondNoteOffset = 0.095
    /// Peak amplitude of the mixed figure — moderate by construction, so the
    /// user-facing loudness knob is the player volume alone.
    private static let peak: Float = 0.4

    /// Rising fourth: open, questioning — "say a profile".
    public static func promptWAV() -> Data { wav(pair(lowNote, highNote)) }
    /// The mirror image, falling: settled — "using it".
    public static func latchWAV() -> Data { wav(pair(highNote, lowNote)) }

    /// Two overlapping strokes of one voice, normalized to `peak` with a
    /// short final fade so the buffer can't click at either end.
    static func pair(_ first: Double, _ second: Double,
                     voice: Voice = strikeVoice) -> [Float] {
        let offset = Int(secondNoteOffset * sampleRate)
        let a = note(first, voice: voice), b = note(second, voice: voice)
        var mix = [Float](repeating: 0, count: offset + b.count)
        for (i, v) in a.enumerated() { mix[i] += v }
        for (i, v) in b.enumerated() { mix[offset + i] += v }

        let maxAbs = mix.reduce(Float(0)) { max($0, abs($1)) }
        if maxAbs > 0 { for i in mix.indices { mix[i] *= peak / maxAbs } }

        let fade = min(Int(0.015 * sampleRate), mix.count)
        for i in 0..<fade {
            mix[mix.count - fade + i] *= Float(fade - 1 - i) / Float(fade)
        }
        return mix
    }

    /// One stroke: the voice's partials on their own decay clocks, a
    /// lightly lowpassed contact transient, and a short attack ramp over
    /// everything so the buffer starts at zero.
    static func note(_ frequency: Double, voice: Voice = strikeVoice) -> [Float] {
        let count = Int(voice.ring * sampleRate)
        let attack = Int(0.003 * sampleRate)
        var rng: UInt32 = 0x5EED_C41E // fixed seed: identical bytes every build
        var n1 = 0.0, n2 = 0.0
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            var sample = 0.0
            for p in voice.partials {
                sample += p.amplitude * sin(2 * .pi * frequency * p.ratio * t)
                    * exp(-t / p.decay)
            }
            rng = rng &* 1_664_525 &+ 1_013_904_223
            let white = Double(Int32(bitPattern: rng)) / Double(Int32.max)
            sample += voice.strike * (white + n1 + n2) / 3 * exp(-t / voice.strikeDecay)
            n2 = n1; n1 = white
            if i < attack { sample *= Double(i) / Double(attack) }
            return Float(sample)
        }
    }

    /// Minimal 16-bit mono PCM WAV wrapper — just enough for AVAudioPlayer.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append(_ s: String) { data.append(contentsOf: s.utf8) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        let rate = UInt32(sampleRate)
        append("RIFF"); append32(36 + UInt32(samples.count * 2)); append("WAVE")
        append("fmt "); append32(16)
        append16(1); append16(1) // PCM, mono
        append32(rate); append32(rate * 2) // byte rate = rate × blockAlign
        append16(2); append16(16) // blockAlign, bits per sample
        append("data"); append32(UInt32(samples.count * 2))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16((clamped * 32767).rounded())))
        }
        return data
    }
}
