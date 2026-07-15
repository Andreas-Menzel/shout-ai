// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import ShoutCore

/// Controls Spotify and Apple Music through their AppleScript interfaces.
///
/// Scripts run via `osascript` out of process, so a busy player — or the
/// one-time Automation consent dialog, which blocks the Apple event until the
/// user answers — can never stall the app. A player is only addressed while
/// running (checked both here and inside the script): sending an Apple event
/// to a quit player would relaunch it.
struct AppleScriptMediaControl: MediaPlayerControl {
    /// Kill deadline for a wedged script. Generous on purpose: the first-ever
    /// pause sits inside the consent dialog until the user answers, and killing
    /// it early would throw the answer away. A timeout just leaves that player
    /// playing (or, on the resume side, paused).
    private static let scriptDeadline: TimeInterval = 25

    func pauseActivePlayers() async -> [MediaPlayer] {
        var paused: [MediaPlayer] = []
        for player in MediaPlayer.known where Self.isRunning(player) {
            if await Self.run(Self.pauseScript(for: player)) == "paused" {
                Log.app.info("Paused \(player.name, privacy: .public) for dictation")
                paused.append(player)
            }
        }
        return paused
    }

    func resume(_ players: [MediaPlayer]) async {
        for player in players where Self.isRunning(player) {
            _ = await Self.run(Self.resumeScript(for: player))
        }
    }

    private static func isRunning(_ player: MediaPlayer) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    private static func pauseScript(for player: MediaPlayer) -> String {
        """
        if not (application id "\(player.bundleID)" is running) then return "not-running"
        with timeout of 5 seconds
            tell application id "\(player.bundleID)"
                if player state is playing then
                    pause
                    return "paused"
                end if
            end tell
        end timeout
        return "not-playing"
        """
    }

    /// Resumes only from `paused` — if the user pressed play themselves during
    /// the dictation (state playing) or stopped entirely, their choice stands.
    private static func resumeScript(for player: MediaPlayer) -> String {
        """
        if not (application id "\(player.bundleID)" is running) then return "not-running"
        with timeout of 5 seconds
            tell application id "\(player.bundleID)"
                if player state is paused then play
            end tell
        end timeout
        return "done"
        """
    }

    /// Runs a script and returns its trimmed stdout, or nil on any failure
    /// (script error, Automation permission denied, deadline kill).
    private static func run(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { finished in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                guard finished.terminationStatus == 0 else {
                    let message = (String(data: err, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.app.error("Media control script failed: \(message, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: out, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                Log.app.error("Could not launch osascript: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + scriptDeadline) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
