// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// Semantic fn/esc events emitted by the key monitor and consumed by the
/// gesture recognizer. Shared so the app and the `fnwatch` diagnostic drive the
/// exact same logic.
public enum FnEvent: Equatable, Sendable {
    case fnDown
    case fnUp(heldDuration: TimeInterval)
    case otherKeyDown
    case escapePressed
}

/// The recording situation the recognizer needs to interpret an event. `.idle`
/// means "a new dictation may begin" (the app's idle *and* transient-notice
/// phases); `.busy` is transcribing/rewriting.
public enum FnRecordingState: Equatable, Sendable {
    case idle
    case recordingUnlocked
    case recordingLocked
    case busy
}

public struct FnGestureConfig: Equatable, Sendable {
    /// Presses shorter than this are taps; longer are hold-to-talk.
    public let holdThreshold: TimeInterval
    /// Window to wait for the second tap of a double-tap.
    public let doubleTapWindow: TimeInterval

    public init(holdThreshold: TimeInterval, doubleTapWindow: TimeInterval) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }
}

/// What the recognizer decides should happen. The caller performs the effects
/// (starting the recorder, running the pipeline, scheduling the double-tap
/// timer) — the recognizer stays pure and testable.
public enum FnGestureIntent: Equatable, Sendable {
    case begin            // start a new (unlocked) recording
    case lock             // promote the current recording to hands-free
    case finish           // finish and transcribe
    case cancel           // discard the current recording
    case armDoubleTap     // schedule `doubleTapTimedOut()` after `doubleTapWindow`
    case disarmDoubleTap  // cancel any pending double-tap timer
}

/// Pure state machine for the fn dictation gestures: hold-to-talk, double-tap to
/// lock hands-free, tap-to-finish, and combo/typing aborts. Holds only the small
/// amount of gesture bookkeeping; the recording phase lives with the caller and
/// is passed in per event, so there is a single source of truth.
public final class FnGestureRecognizer {
    private var awaitingSecondTap = false
    private var ignoreNextFnUp = false
    private var holdCancelledByCombo = false

    public init() {}

    /// Clear in-flight gesture bookkeeping (e.g. when the caller finishes or
    /// cancels a recording out of band, such as from the menu or a watchdog).
    public func reset() {
        awaitingSecondTap = false
        ignoreNextFnUp = false
        holdCancelledByCombo = false
    }

    public func handle(
        _ event: FnEvent,
        recording: FnRecordingState,
        isFnDown: Bool,
        config: FnGestureConfig
    ) -> [FnGestureIntent] {
        switch event {
        case .fnDown:
            if recording == .recordingUnlocked, awaitingSecondTap {
                // Second tap of a double-tap: lock hands-free mode.
                awaitingSecondTap = false
                ignoreNextFnUp = true
                return [.disarmDoubleTap, .lock]
            } else if recording == .idle {
                holdCancelledByCombo = false
                return [.begin]
            }
            return []

        case .fnUp(let heldDuration):
            if holdCancelledByCombo {
                holdCancelledByCombo = false
                return []
            }
            if ignoreNextFnUp {
                ignoreNextFnUp = false
                return []
            }
            switch recording {
            case .recordingLocked:
                // A tap while locked ends the dictation.
                return [.finish]
            case .recordingUnlocked:
                if heldDuration >= config.holdThreshold {
                    return [.finish]                 // push-to-talk release
                } else {
                    // Short tap: wait for a possible second tap; else discard.
                    awaitingSecondTap = true
                    return [.armDoubleTap]
                }
            default:
                return []
            }

        case .otherKeyDown:
            if recording == .recordingUnlocked {
                if isFnDown {
                    // Fn is being used as a modifier (fn+arrow etc.) — abort.
                    holdCancelledByCombo = true
                    return [.cancel]
                } else if awaitingSecondTap {
                    // User tapped fn then typed — not a dictation.
                    awaitingSecondTap = false
                    return [.disarmDoubleTap, .cancel]
                }
            }
            return []

        case .escapePressed:
            if recording == .recordingUnlocked || recording == .recordingLocked {
                awaitingSecondTap = false
                return [.disarmDoubleTap, .cancel]
            }
            return []
        }
    }

    /// The awaited second tap never arrived: the earlier short tap was not a
    /// double-tap, so the tentative recording is discarded.
    public func doubleTapTimedOut() -> [FnGestureIntent] {
        guard awaitingSecondTap else { return [] }
        awaitingSecondTap = false
        return [.cancel]
    }
}
