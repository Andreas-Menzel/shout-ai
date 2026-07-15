// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

final class FnGestureRecognizerTests: XCTestCase {
    private let config = FnGestureConfig(holdThreshold: 0.5, doubleTapWindow: 0.6)

    private func makeRecognizer() -> FnGestureRecognizer { FnGestureRecognizer() }

    // Hold-to-talk: press from idle begins; a long release finishes.
    func testHoldToTalk() {
        let r = makeRecognizer()
        XCTAssertEqual(r.handle(.fnDown, recording: .idle, isFnDown: true, config: config), [.begin])
        XCTAssertEqual(
            r.handle(.fnUp(heldDuration: 1.0), recording: .recordingUnlocked, isFnDown: false, config: config),
            [.finish])
    }

    // A short release arms the double-tap wait rather than finishing.
    func testShortTapArmsDoubleTap() {
        let r = makeRecognizer()
        _ = r.handle(.fnDown, recording: .idle, isFnDown: true, config: config)
        XCTAssertEqual(
            r.handle(.fnUp(heldDuration: 0.1), recording: .recordingUnlocked, isFnDown: false, config: config),
            [.armDoubleTap])
    }

    // Double-tap: short tap, then a second press locks hands-free.
    func testDoubleTapLocks() {
        let r = makeRecognizer()
        _ = r.handle(.fnDown, recording: .idle, isFnDown: true, config: config)
        _ = r.handle(.fnUp(heldDuration: 0.1), recording: .recordingUnlocked, isFnDown: false, config: config)
        // Second tap arrives while still unlocked and awaiting.
        XCTAssertEqual(
            r.handle(.fnDown, recording: .recordingUnlocked, isFnDown: true, config: config),
            [.disarmDoubleTap, .lock])
        // The fnUp that ends the locking press is swallowed (ignoreNextFnUp).
        XCTAssertEqual(
            r.handle(.fnUp(heldDuration: 0.1), recording: .recordingLocked, isFnDown: false, config: config),
            [])
        // A later tap while locked finishes.
        XCTAssertEqual(
            r.handle(.fnUp(heldDuration: 0.1), recording: .recordingLocked, isFnDown: false, config: config),
            [.finish])
    }

    // The awaited second tap never comes → discard.
    func testDoubleTapTimeoutCancels() {
        let r = makeRecognizer()
        _ = r.handle(.fnDown, recording: .idle, isFnDown: true, config: config)
        _ = r.handle(.fnUp(heldDuration: 0.1), recording: .recordingUnlocked, isFnDown: false, config: config)
        XCTAssertEqual(r.doubleTapTimedOut(), [.cancel])
        // Idempotent: a second timeout does nothing.
        XCTAssertEqual(r.doubleTapTimedOut(), [])
    }

    // fn used as a modifier (fn+arrow) aborts the tentative recording.
    func testComboAborts() {
        let r = makeRecognizer()
        _ = r.handle(.fnDown, recording: .idle, isFnDown: true, config: config)
        XCTAssertEqual(
            r.handle(.otherKeyDown, recording: .recordingUnlocked, isFnDown: true, config: config),
            [.cancel])
    }

    // Typing after a short tap (fn released) cancels the pending double-tap.
    func testTypingAfterTapCancels() {
        let r = makeRecognizer()
        _ = r.handle(.fnDown, recording: .idle, isFnDown: true, config: config)
        _ = r.handle(.fnUp(heldDuration: 0.1), recording: .recordingUnlocked, isFnDown: false, config: config)
        XCTAssertEqual(
            r.handle(.otherKeyDown, recording: .recordingUnlocked, isFnDown: false, config: config),
            [.disarmDoubleTap, .cancel])
    }

    // Esc while recording cancels; Esc while idle/busy is not a gesture.
    func testEscape() {
        let r = makeRecognizer()
        XCTAssertEqual(
            r.handle(.escapePressed, recording: .recordingUnlocked, isFnDown: false, config: config),
            [.disarmDoubleTap, .cancel])
        XCTAssertEqual(r.handle(.escapePressed, recording: .idle, isFnDown: false, config: config), [])
        XCTAssertEqual(r.handle(.escapePressed, recording: .busy, isFnDown: false, config: config), [])
    }

    // A press while busy (transcribing/rewriting) starts nothing.
    func testNoBeginWhileBusy() {
        let r = makeRecognizer()
        XCTAssertEqual(r.handle(.fnDown, recording: .busy, isFnDown: true, config: config), [])
    }
}
