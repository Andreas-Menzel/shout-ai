// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// A music player Shout knows how to pause and resume around a dictation.
public struct MediaPlayer: Equatable, Sendable {
    public let name: String
    public let bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }

    public static let spotify = MediaPlayer(name: "Spotify", bundleID: "com.spotify.client")
    public static let appleMusic = MediaPlayer(name: "Music", bundleID: "com.apple.Music")

    /// Players probed at dictation start. Both speak the same AppleScript
    /// vocabulary (player state / pause / play).
    public static let known: [MediaPlayer] = [.spotify, .appleMusic]
}

/// Pausing and resuming players. Implemented in the app layer (Apple events);
/// a protocol here so the coordinator's sequencing is testable with fakes.
public protocol MediaPlayerControl: Sendable {
    /// Pauses every known player that is currently playing.
    /// Returns the players actually paused (empty when nothing was playing).
    func pauseActivePlayers() async -> [MediaPlayer]

    /// Resumes the given players if they are still paused. A player the user
    /// resumed or quit in the meantime is left alone.
    func resume(_ players: [MediaPlayer]) async
}

/// Pauses music when dictation starts and resumes exactly what it paused when
/// dictation ends.
///
/// The pause runs asynchronously so recording start never waits on a player
/// (or on the one-time Automation consent dialog). The resume awaits the
/// pause's outcome, so a take that ends while its pause is still in flight
/// still gets the matching resume. Operations are chained strictly
/// pause → resume → pause: without the chain, ending a take and starting the
/// next could interleave — the new take's pause probing the player *before*
/// the previous resume lands would see "already paused", skip it, and the
/// stale resume would then restart music mid-recording.
@MainActor
public final class MediaPauseCoordinator {
    private let control: any MediaPlayerControl
    /// The in-flight pause of the current take, consumed by `dictationDidEnd`.
    private var pendingPause: Task<[MediaPlayer], Never>?
    /// Tail of the pause/resume chain; each new operation awaits it first.
    private var chain: Task<Void, Never>?

    public init(control: any MediaPlayerControl) {
        self.control = control
    }

    public func dictationDidStart(pauseEnabled: Bool) {
        guard pauseEnabled else { return }
        let control = control
        let previous = chain
        let pause = Task { () async -> [MediaPlayer] in
            await previous?.value
            return await control.pauseActivePlayers()
        }
        pendingPause = pause
        chain = Task { _ = await pause.value }
    }

    public func dictationDidEnd() {
        // Nothing pending when the feature is off or start never fired; a take
        // recorded with the setting on is still resumed if it was toggled off
        // mid-take.
        guard let pause = pendingPause else { return }
        pendingPause = nil
        let control = control
        let previous = chain
        chain = Task { () async -> Void in
            await previous?.value
            let paused = await pause.value
            guard !paused.isEmpty else { return }
            await control.resume(paused)
        }
    }

    /// Awaits completion of all pause/resume work queued so far.
    public func settle() async {
        _ = await chain?.value
    }
}
