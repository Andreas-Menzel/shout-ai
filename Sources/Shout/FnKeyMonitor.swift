// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import CoreGraphics
import ShoutCore

/// Watches the Fn/Globe key system-wide via a listen-only CGEventTap.
/// Emits semantic events; the AppState interprets them into gestures.
/// Requires the Input Monitoring permission.
final class FnKeyMonitor {
    typealias Event = FnEvent

    var handler: ((Event) -> Void)?
    private(set) var isFnDown = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDownAt: CFAbsoluteTime = 0

    private static let fnKeyCode: Int64 = 63       // fn/Globe in flagsChanged
    private static let globeKeyDownCode: Int64 = 179 // fn/Globe's own keyDown on tap
    private static let escapeKeyCode: Int64 = 53

    /// Returns false when the event tap could not be created (no Input Monitoring permission).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.notice("Event tap creation failed (Input Monitoring not granted yet)")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.app.notice("Fn key monitor active (tap created)")
        return true
    }

    /// The system silently disables taps that miss their latency budget
    /// (App Nap, heavy load, secure input). Revive ours if that happened.
    func ensureEnabled() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            reEnable(tap)
            Log.app.notice("Re-enabled fn event tap after the system disabled it")
        }
    }

    /// Re-enable a tap the system disabled. If we thought fn was held, its release
    /// happened while the tap was dead and we missed it — synthesize the up so the
    /// app resolves the in-flight gesture instead of getting stuck "recording".
    private func reEnable(_ tap: CFMachPort) {
        CGEvent.tapEnable(tap: tap, enable: true)
        if isFnDown {
            isFnDown = false
            emit(.fnUp(heldDuration: CFAbsoluteTimeGetCurrent() - fnDownAt))
            Log.app.notice("Recovered fn state after the tap was re-enabled mid-press")
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables taps that stall or when secure input starts; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { reEnable(tap) }
            return
        }

        switch type {
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == Self.fnKeyCode else { return }
            let down = event.flags.contains(.maskSecondaryFn)
            if down, !isFnDown {
                isFnDown = true
                fnDownAt = CFAbsoluteTimeGetCurrent()
                emit(.fnDown)
            } else if !down, isFnDown {
                isFnDown = false
                emit(.fnUp(heldDuration: CFAbsoluteTimeGetCurrent() - fnDownAt))
            }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // The Globe/fn key emits its OWN keyDown (179) whenever it is
            // tapped, alongside the flagsChanged. That is the dictation key
            // itself, not "another key" — swallowing it here is essential, or
            // it fires .otherKeyDown 1 ms after the first tap and cancels every
            // pending double-tap. (It is not emitted on a hold, so push-to-talk
            // was never affected.)
            if keyCode == Self.globeKeyDownCode || keyCode == Self.fnKeyCode { return }
            emit(keyCode == Self.escapeKeyCode ? .escapePressed : .otherKeyDown)
        default:
            break
        }
    }

    private func emit(_ event: Event) {
        // The tap runs on the main run loop; dispatch keeps handler work off the tap callback.
        DispatchQueue.main.async { [weak self] in
            self?.handler?(event)
        }
    }
}
