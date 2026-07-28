// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// Energy-based speech detection against an adaptive ambient floor, shared by
/// the pill's stop hint and the voice-switch prompt cue. The speech threshold
/// rides `speechMargin` above a tracked noise floor, so a quiet talker (or a
/// noisy room) is judged against their own room tone rather than a fixed
/// cutoff.
///
/// The heuristic reliably separates speech from quiet/moderate rooms; a
/// genuinely loud, variable room can still mask it (energy alone can't tell a
/// noise spike from a syllable), so consumers must fail safe in that
/// direction — the stop hint arrives late or not at all, the prompt cue falls
/// back to its deadline.
///
/// Timestamps are injected, keeping the logic pure and testable.
public struct VoiceActivityTracker: Sendable {
    /// How far above the noise floor a sample must rise to count as speech.
    static let speechMargin: Float = 0.03
    /// Floor tracking: fall fast toward new quiet (locking onto silence in
    /// the gaps between words), rise gently so speech energy doesn't drag the
    /// floor — and thus the threshold — up to meet it.
    private static let floorAttack: Float = 0.4
    private static let floorRelease: Float = 0.02

    /// `-1` until the first sample of a take seeds it with the room tone
    /// (recording starts before the user speaks).
    private var noiseFloor: Float = -1
    /// The last sample that read as speech — or the first sample ever fed, so
    /// silence is measurable from take start even when speech never crosses
    /// the floor.
    private var reference: Date?

    public init() {}

    /// Feeds one level sample; returns whether it reads as speech.
    @discardableResult
    public mutating func feed(level: Float, at now: Date) -> Bool {
        if reference == nil { reference = now }
        if noiseFloor < 0 {
            noiseFloor = level
            return false
        }
        let rate = level < noiseFloor ? Self.floorAttack : Self.floorRelease
        noiseFloor += (level - noiseFloor) * rate
        guard level > noiseFloor + Self.speechMargin else { return false }
        reference = now
        return true
    }

    /// Seconds of unbroken silence ending at `now`: since the last speech
    /// sample, since the first sample when nothing has read as speech yet, or
    /// zero before any sample arrives.
    public func silence(at now: Date) -> TimeInterval {
        guard let reference else { return 0 }
        return now.timeIntervalSince(reference)
    }
}
