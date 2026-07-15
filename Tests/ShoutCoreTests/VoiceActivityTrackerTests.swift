// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

/// The adaptive-floor speech detector shared by the pill's stop hint and the
/// voice-switch prompt cue: levels are judged against the take's own room
/// tone, and `silence(at:)` reports how long the user has been quiet.
final class VoiceActivityTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testFirstSampleSeedsFloorWithoutReadingAsSpeech() {
        var tracker = VoiceActivityTracker()
        // Even a loud first sample only calibrates the floor.
        XCTAssertFalse(tracker.feed(level: 0.5, at: t0))
    }

    func testSpeechIsLevelAboveFloorPlusMargin() {
        var tracker = VoiceActivityTracker()
        tracker.feed(level: 0.04, at: t0) // room tone
        XCTAssertFalse(tracker.feed(level: 0.05, at: at(0.1)), "within the margin")
        XCTAssertTrue(tracker.feed(level: 0.2, at: at(0.2)))
    }

    func testFloorRisesTooSlowlyForSpeechToMaskItself() {
        var tracker = VoiceActivityTracker()
        tracker.feed(level: 0.04, at: t0)
        // A sustained utterance (~3.5 s at the ~85 ms level cadence) must keep
        // reading as speech — the release rate can't drag the floor up to it.
        for i in 1...40 {
            XCTAssertTrue(tracker.feed(level: 0.3, at: at(Double(i) * 0.085)),
                          "sample \(i) swallowed by a risen floor")
        }
    }

    func testFloorFallsFastSoSpeechAfterAGapStillRegisters() {
        var tracker = VoiceActivityTracker()
        tracker.feed(level: 0.04, at: t0)
        for i in 1...20 { tracker.feed(level: 0.3, at: at(Double(i) * 0.085)) }
        // Two quiet samples collapse the risen floor back toward room tone…
        XCTAssertFalse(tracker.feed(level: 0.04, at: at(2.0)))
        XCTAssertFalse(tracker.feed(level: 0.04, at: at(2.1)))
        // …so moderate speech right after the gap is still caught.
        XCTAssertTrue(tracker.feed(level: 0.2, at: at(2.2)))
    }

    func testSilenceRunsFromLastSpeechSample() {
        var tracker = VoiceActivityTracker()
        XCTAssertEqual(tracker.silence(at: t0), 0, "no samples yet")
        tracker.feed(level: 0.04, at: t0)
        tracker.feed(level: 0.3, at: at(0.5)) // speech
        tracker.feed(level: 0.04, at: at(0.6))
        tracker.feed(level: 0.04, at: at(1.0))
        XCTAssertEqual(tracker.silence(at: at(1.5)), 1.0, accuracy: 0.001)
    }

    func testSilenceMeasurableFromFirstSampleWhenNothingReadsAsSpeech() {
        var tracker = VoiceActivityTracker()
        tracker.feed(level: 0.04, at: t0)
        tracker.feed(level: 0.045, at: at(0.5)) // hovering at room tone
        XCTAssertEqual(tracker.silence(at: at(0.8)), 0.8, accuracy: 0.001,
                       "a too-quiet talker must still accrue silence, not stall the cue")
    }
}
