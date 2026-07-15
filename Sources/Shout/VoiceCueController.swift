// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AVFoundation
import ShoutCore

/// The audible half of voice-profile switching: a rising cue when the profile
/// list opens ("name a profile") and a falling cue when one latches ("locked
/// in"). Split out of `AppState` so the chime timing — a subtle silence/deadline
/// race — lives in one small, self-contained place.
///
/// The rising cue fires the moment the user reads as having stopped talking, so
/// a fluid "trigger + name in one breath" (voice energy active until the latch
/// cancels the cue) stays silent, while a deliberate pause after the trigger —
/// which usually banks `silenceThreshold` of quiet during decode latency — gets
/// the cue together with the list. `deadline` guarantees the cue when a loud or
/// variable room keeps the energy floor from ever reading as silent.
@MainActor
final class VoiceCueController {
    /// The synthesized sibling cues (see `ChimeSynth` — one bell voice, rising
    /// asks / falling confirms), built and preloaded once so the first cue of a
    /// session doesn't pay setup latency: these are timing cues, and a late
    /// chime reads as a laggy app.
    private let promptSound = try? AVAudioPlayer(data: ChimeSynth.promptWAV())
    private let latchSound = try? AVAudioPlayer(data: ChimeSynth.latchWAV())

    /// Energy-based silence tracking for the prompt cue. Deliberately NOT fed
    /// interim word ticks (unlike the pill's stop hint): a decode reports words
    /// spoken hundreds of ms earlier, and counting them as activity *now* would
    /// re-delay the cue in exactly the paused case it exists for.
    private var voiceActivity = VoiceActivityTracker()

    private var promptChime: Task<Void, Never>?
    /// Once per recording — noisy interim decodes can briefly flap the state out
    /// of the list and back, and the reopened list must not beep again.
    private var promptChimePlayed = false

    /// Unbroken quiet that counts as "stopped talking". A pause after the trigger
    /// has usually banked this much during decode latency already, so the cue
    /// lands together with the list itself.
    private let silenceThreshold: TimeInterval = 0.5
    /// Backstop for rooms too loud/variable for the energy floor to ever read as
    /// silent: the cue is guaranteed this long after the list opens.
    private let deadline: TimeInterval = 1.2

    init() {
        promptSound?.prepareToPlay()
        latchSound?.prepareToPlay()
    }

    /// Feed one mic level for silence tracking (drives the prompt-cue timing).
    func feed(level: Float, at time: Date) {
        voiceActivity.feed(level: level, at: time)
    }

    /// Reset for a new take: re-seed the tracker from this take's room tone and
    /// clear the once-per-recording chime latch. Any pending cue is cancelled.
    func beginTake() {
        voiceActivity = VoiceActivityTracker()
        promptChimePlayed = false
        cancelPromptChime()
    }

    /// Arms the rising cue that mirrors the profile list opening. `isListVisible`
    /// is re-checked every step — a release or cancel while the cue is pending
    /// must not beep into the notice that follows.
    func schedulePromptChime(isListVisible: @escaping @MainActor () -> Bool) {
        guard !promptChimePlayed, promptChime == nil else { return }
        promptChime = Task { @MainActor [weak self] in
            let armed = Date.now
            while !Task.isCancelled {
                guard let self, isListVisible() else { return }
                let now = Date.now
                if self.voiceActivity.silence(at: now) >= self.silenceThreshold
                    || now.timeIntervalSince(armed) >= self.deadline {
                    self.promptChimePlayed = true
                    self.play(self.promptSound)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func cancelPromptChime() {
        promptChime?.cancel()
        promptChime = nil
    }

    /// The falling figure — "locked in": the prompt's mirror image, so the pair
    /// are audibly about the same thing while the contour says which moment this
    /// is. Non-speech, so a mic that picks it up gives the transcriber nothing
    /// to mishear.
    func playLatchChime() {
        play(latchSound)
    }

    /// Rewind-and-play; AVAudioPlayer resumes from where it stopped otherwise.
    /// Loudness knob for both cues: `sound.volume` here (the waveforms themselves
    /// peak at a fixed moderate level, see ChimeSynth).
    private func play(_ sound: AVAudioPlayer?) {
        guard let sound else { return }
        sound.currentTime = 0
        sound.volume = 1.0
        sound.play()
    }
}
