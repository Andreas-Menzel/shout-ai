// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

@MainActor
final class MediaPauseCoordinatorTests: XCTestCase {

    func testPausesOnStartAndResumesWhatItPaused() async {
        let control = FakeMediaControl(playing: [.spotify])
        let coordinator = MediaPauseCoordinator(control: control)
        coordinator.dictationDidStart(pauseEnabled: true)
        coordinator.dictationDidEnd()
        await coordinator.settle()
        XCTAssertEqual(control.log, ["pause", "resume(Spotify)"])
    }

    func testDisabledTouchesNothing() async {
        let control = FakeMediaControl(playing: [.spotify])
        let coordinator = MediaPauseCoordinator(control: control)
        coordinator.dictationDidStart(pauseEnabled: false)
        coordinator.dictationDidEnd()
        await coordinator.settle()
        XCTAssertEqual(control.log, [])
    }

    func testNothingPlayingMeansNoResume() async {
        let control = FakeMediaControl(playing: [])
        let coordinator = MediaPauseCoordinator(control: control)
        coordinator.dictationDidStart(pauseEnabled: true)
        coordinator.dictationDidEnd()
        await coordinator.settle()
        XCTAssertEqual(control.log, ["pause"])
    }

    func testEndWithoutStartIsANoop() async {
        let control = FakeMediaControl(playing: [.spotify])
        let coordinator = MediaPauseCoordinator(control: control)
        coordinator.dictationDidEnd()
        await coordinator.settle()
        XCTAssertEqual(control.log, [])
    }

    func testResumesBothPlayersItPaused() async {
        let control = FakeMediaControl(playing: [.spotify, .appleMusic])
        let coordinator = MediaPauseCoordinator(control: control)
        coordinator.dictationDidStart(pauseEnabled: true)
        coordinator.dictationDidEnd()
        await coordinator.settle()
        XCTAssertEqual(control.log, ["pause", "resume(Spotify+Music)"])
    }

    /// The take can end while its pause is still in flight (short takes; the
    /// first-ever pause waits inside the Automation consent dialog). The resume
    /// must wait for the pause's outcome instead of resuming nothing.
    func testEndBeforePauseCompletesStillResumes() async {
        let control = FakeMediaControl(playing: [.spotify])
        control.holdNextPause()
        let coordinator = MediaPauseCoordinator(control: control)
        coordinator.dictationDidStart(pauseEnabled: true)
        coordinator.dictationDidEnd()
        await control.waitUntilPauseHeld()
        XCTAssertEqual(control.log, [], "nothing may happen while the pause is stuck")
        control.releasePause()
        await coordinator.settle()
        XCTAssertEqual(control.log, ["pause", "resume(Spotify)"])
    }

    /// Back-to-back takes: the second take's pause must not overtake the first
    /// take's (slow) resume — it would see "already paused", skip the player,
    /// and the stale resume would then restart music mid-recording.
    func testQuickRestartKeepsPauseResumeOrder() async {
        let control = FakeMediaControl(playing: [.spotify])
        control.resumeDelayNanos = 50_000_000
        let coordinator = MediaPauseCoordinator(control: control)
        coordinator.dictationDidStart(pauseEnabled: true)
        coordinator.dictationDidEnd()
        coordinator.dictationDidStart(pauseEnabled: true)
        coordinator.dictationDidEnd()
        await coordinator.settle()
        XCTAssertEqual(control.log, ["pause", "resume(Spotify)", "pause", "resume(Spotify)"])
    }
}

/// Records pause/resume calls in order; can hold a pause open to simulate the
/// consent dialog and delay resumes to expose ordering races.
private final class FakeMediaControl: MediaPlayerControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private let playing: [MediaPlayer]
    private var _holdPause = false
    private var _pauseGate: CheckedContinuation<Void, Never>?
    private var _resumeDelayNanos: UInt64 = 0

    init(playing: [MediaPlayer]) {
        self.playing = playing
    }

    var log: [String] {
        lock.lock(); defer { lock.unlock() }
        return _log
    }

    var resumeDelayNanos: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _resumeDelayNanos }
        set { lock.lock(); defer { lock.unlock() }; _resumeDelayNanos = newValue }
    }

    /// Makes the next pauseActivePlayers() suspend until releasePause().
    func holdNextPause() {
        lock.lock(); defer { lock.unlock() }
        _holdPause = true
    }

    func releasePause() {
        lock.lock()
        let gate = _pauseGate
        _pauseGate = nil
        lock.unlock()
        gate?.resume()
    }

    func waitUntilPauseHeld() async {
        while true {
            lock.lock()
            let held = _pauseGate != nil
            lock.unlock()
            if held { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func pauseActivePlayers() async -> [MediaPlayer] {
        lock.lock()
        let shouldHold = _holdPause
        _holdPause = false
        lock.unlock()
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.lock()
                _pauseGate = continuation
                lock.unlock()
            }
        }
        lock.lock()
        _log.append("pause")
        lock.unlock()
        return playing
    }

    func resume(_ players: [MediaPlayer]) async {
        let delay = resumeDelayNanos
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        lock.lock()
        _log.append("resume(" + players.map(\.name).joined(separator: "+") + ")")
        lock.unlock()
    }
}
