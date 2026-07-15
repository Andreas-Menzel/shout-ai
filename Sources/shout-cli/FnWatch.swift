// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import CoreGraphics
import ShoutCore

/// Ground-truth diagnostic for the fn key. Creates the same listen-only event
/// tap the app uses and logs every fn/key event with precise timing, plus the
/// intents the SHARED `FnGestureRecognizer` emits for each — so the diagnostic
/// and the app can never drift (they run identical gesture logic).
///
/// Run from a Terminal that has Input Monitoring (the grant sticks to Terminal,
/// which is Apple-signed), so it never disturbs the Shout app or its permissions.
///
///   shout-cli fnwatch [seconds]
enum FnWatch {
    private static let fnKeyCode: Int64 = 63
    private static let globeKeyDownCode: Int64 = 179
    private static let escapeKeyCode: Int64 = 53

    // Raw detection mirror of FnKeyMonitor.
    static var isFnDown = false
    static var fnDownAt: CFAbsoluteTime = 0
    static var startTime: CFAbsoluteTime = 0
    static var lastEventAt: CFAbsoluteTime = 0

    // Identical config + logic to the app.
    private static let config = FnGestureConfig(holdThreshold: 0.5, doubleTapWindow: 0.6)
    private static let recognizer = FnGestureRecognizer()
    private static var recording: FnRecordingState = .idle

    static var logHandle: FileHandle?

    static func run(seconds: Double) {
        let logURL = ShoutPaths.appSupportDir.appendingPathComponent("fnwatch.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        logHandle = try? FileHandle(forWritingTo: logURL)

        emit("=== fnwatch started; will run \(Int(seconds))s ===")
        emit("Do this: (1) DOUBLE-TAP fn, pause 2s, then TAP once.  (2) HOLD fn ~1s and release.  Repeat 2–3×.")
        emit("thresholds: holdThreshold=\(config.holdThreshold)s doubleTapWindow=\(config.doubleTapWindow)s")
        emit("")

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, _ in
                FnWatch.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: nil
        ) else {
            emit("!! Could not create event tap. Grant Terminal 'Input Monitoring' in")
            emit("!! System Settings › Privacy & Security › Input Monitoring, then rerun.")
            exit(1)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startTime = CFAbsoluteTimeGetCurrent()
        lastEventAt = startTime
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            emit("")
            emit("=== fnwatch done ===")
            FnWatch.logHandle?.closeFile()
            exit(0)
        }
        CFRunLoopRun()
    }

    private static func handle(type: CGEventType, event: CGEvent) {
        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == fnKeyCode else { return }
            let down = event.flags.contains(.maskSecondaryFn)
            let now = CFAbsoluteTimeGetCurrent()
            if down, !isFnDown {
                isFnDown = true
                fnDownAt = now
                logEvent("FN_DOWN", now: now)
                decide(.fnDown)
            } else if !down, isFnDown {
                isFnDown = false
                let held = now - fnDownAt
                logEvent(String(format: "FN_UP   held=%.3fs", held), now: now)
                decide(.fnUp(heldDuration: held))
            } else {
                logEvent("FN_flags(dup down=\(down) isFnDown=\(isFnDown)) <-- SUSPICIOUS", now: now)
            }
        } else if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let now = CFAbsoluteTimeGetCurrent()
            // The fn/Globe key's own keyDown (179/63) is swallowed, exactly like
            // FnKeyMonitor, so it can't cancel a pending double-tap.
            if keyCode == globeKeyDownCode || keyCode == fnKeyCode {
                logEvent("KEY_DOWN code=\(keyCode) (fn key itself — IGNORED)", now: now)
                return
            }
            // Never record the raw keycode of a non-fn key: the recognizer only
            // needs "Escape" vs "some other key", and this diagnostic must not
            // persist a reconstructable trace of what the user typed elsewhere.
            logEvent(keyCode == escapeKeyCode ? "ESC" : "KEY_DOWN (other key)", now: now)
            decide(keyCode == escapeKeyCode ? .escapePressed : .otherKeyDown)
        }
    }

    /// Drives the shared recognizer and applies the resulting intents, exactly
    /// as `AppState` does — annotating each decision.
    private static func decide(_ event: FnEvent) {
        apply(recognizer.handle(event, recording: recording, isFnDown: isFnDown, config: config))
    }

    private static func apply(_ intents: [FnGestureIntent]) {
        for intent in intents {
            switch intent {
            case .begin: recording = .recordingUnlocked; note("→ begin recording (unlocked)")
            case .lock: recording = .recordingLocked; note("→ LOCK (hands-free). Recording continues.")
            case .finish: recording = .idle; note("→ FINISH")
            case .cancel: recording = .idle; note("→ CANCEL")
            case .armDoubleTap:
                note("→ short tap: awaiting 2nd tap for \(config.doubleTapWindow)s")
                let timer = Timer(timeInterval: config.doubleTapWindow, repeats: false) { _ in
                    apply(recognizer.doubleTapTimedOut())
                }
                RunLoop.current.add(timer, forMode: .common)
            case .disarmDoubleTap:
                note("→ double-tap window cleared")
            }
        }
    }

    private static func logEvent(_ label: String, now: CFAbsoluteTime) {
        let t = now - startTime
        let gap = now - lastEventAt
        lastEventAt = now
        emit(String(format: "[t=%6.3f  +%.3f] %@", t, gap, label))
    }

    private static func note(_ s: String) {
        emit("            \(s)")
    }

    private static func emit(_ s: String) {
        print(s)
        if let data = (s + "\n").data(using: .utf8) { logHandle?.write(data) }
    }
}
