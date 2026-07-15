// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ShoutCore

/// Inserts text into the focused field of the frontmost app via clipboard +
/// synthetic Cmd-V, then restores the previous clipboard. Posting key events
/// requires the Accessibility permission; when that is missing (or focus has
/// moved, or there is no sensible target) the text stays on the clipboard so
/// nothing is ever lost.
///
/// Safety properties:
///  - The dictation is written as *concealed* pasteboard content, so clipboard
///    managers don't archive it and Universal Clipboard shouldn't relay it.
///  - The paste target is captured when recording starts and re-checked before
///    the keystroke, so a slow pipeline can't paste into whatever the user
///    clicked into meanwhile (a password field, a send-on-paste chat, …).
///  - The clipboard is only restored if nothing else touched it in the interim
///    (guarded by `changeCount`), and the dictation is cleared even when the
///    previous clipboard was empty, so it never lingers.
@MainActor
final class TextInserter {
    enum Outcome {
        case pasted(into: String)
        case leftOnClipboard(reason: String)
    }

    /// The app that was frontmost when dictation began — the intended paste target.
    struct Target: Sendable {
        let bundleID: String?
        let name: String
    }

    private static let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Capture the current frontmost app. Call at record start.
    static func currentTarget() -> Target {
        let app = NSWorkspace.shared.frontmostApplication
        return Target(bundleID: app?.bundleIdentifier, name: app?.localizedName ?? "frontmost app")
    }

    func insert(_ text: String, restoreClipboard: Bool, target: Target?) async -> Outcome {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let targetName = target?.name ?? frontmost?.localizedName ?? "frontmost app"

        // Pasting while Shout's own windows are focused would go nowhere useful.
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            writeConcealed(text)
            Log.app.info("Insert skipped: Shout itself is frontmost; left text on clipboard")
            return .leftOnClipboard(reason: "Copied — click a text field, press ⌘V")
        }

        // Focus moved to a different app than the one dictation started in. Don't
        // blast text somewhere the user didn't intend; leave it for a manual paste.
        if let wanted = target?.bundleID,
           let current = frontmost?.bundleIdentifier,
           current != wanted {
            writeConcealed(text)
            Log.app.info("Insert skipped: focus changed since recording; left text on clipboard")
            return .leftOnClipboard(reason: "Focus changed — copied, press ⌘V")
        }

        // Hard check: without post-event access the ⌘V would be silently
        // dropped. AXIsProcessTrusted updates live when the user grants the
        // permission; the CG preflight is frozen per-process — accept either,
        // and only refuse when both deny.
        guard AXIsProcessTrusted() || CGPreflightPostEventAccess() else {
            writeConcealed(text)
            _ = CGRequestPostEventAccess() // (re-)registers Shout with TCC / prompts
            Log.app.error("Insert blocked: no post-event (Accessibility) access; left text on clipboard")
            return .leftOnClipboard(reason: "Copied — grant Accessibility, press ⌘V")
        }

        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(of: pasteboard) : nil
        writeConcealed(text)
        let writtenChangeCount = pasteboard.changeCount

        // Give the pasteboard a beat to settle before the paste keystroke.
        try? await Task.sleep(nanoseconds: 120_000_000)

        // Re-check the target right before the keystroke. Focus can move during
        // the settle delay (Cmd-Tab, a focus-stealing auth prompt); the same
        // guarantee the record-start capture gives must still hold at the moment
        // of paste, or the dictation lands wherever grabbed focus. The concealed
        // text is already on the clipboard, so a manual ⌘V still recovers it.
        let atPaste = NSWorkspace.shared.frontmostApplication
        if atPaste?.bundleIdentifier == Bundle.main.bundleIdentifier {
            Log.app.info("Insert aborted: Shout became frontmost during settle; left text on clipboard")
            return .leftOnClipboard(reason: "Copied — click a text field, press ⌘V")
        }
        if let wanted = target?.bundleID, let current = atPaste?.bundleIdentifier, current != wanted {
            Log.app.info("Insert aborted: focus changed during settle; left text on clipboard")
            return .leftOnClipboard(reason: "Focus changed — copied, press ⌘V")
        }

        Self.postCmdV()
        Log.app.info("Posted ⌘V into \(targetName, privacy: .private)")

        if restoreClipboard {
            // Restore after the target app has processed the paste — but without
            // blocking the outcome, and only if the user hasn't copied something
            // new in the meantime (which would advance changeCount).
            let saved = saved ?? []
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard pasteboard.changeCount == writtenChangeCount else { return }
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
                // If there was nothing to restore, leaving it cleared means the
                // dictation doesn't linger on the clipboard.
            }
        }
        return .pasted(into: targetName)
    }

    /// Writes `text` to the pasteboard as concealed content, replacing what's there.
    private func writeConcealed(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org convention honored by clipboard managers (Maccy, Paste,
        // Raycast, …): don't archive this, it's sensitive user content.
        item.setData(Data([1]), forType: Self.concealedType)
        pasteboard.writeObjects([item])
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        var saved: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            saved.append(copy)
        }
        return saved
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
