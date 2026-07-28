// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import Observation
import ShoutCore

/// Central coordinator: interprets Fn-key gestures, drives the
/// record → transcribe → rewrite → insert pipeline, and owns all stores.
@MainActor
@Observable
final class AppState {
    /// Outcome flavor of a transient notice, so a non-error ("Didn't catch
    /// anything") isn't shown as a green success, and actionable failures can be
    /// styled and surfaced distinctly.
    enum NoticeKind: Equatable {
        case success, failure, info

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            case .info: return "info.circle"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case recording(locked: Bool)
        case transcribing
        case rewriting
        /// `glyph` is set when the notice confirms a profile switch, so the
        /// pill shows that profile's own icon instead of the generic checkmark.
        case notice(message: String, kind: NoticeKind, glyph: ProfileGlyph?)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isBusy: Bool {
            self == .transcribing || self == .rewriting
        }
    }

    var phase: Phase = .idle {
        didSet {
            // Off-screen documentation renders drive `phase` directly to pose the
            // pill; the live floating panel and media-pause control must stay
            // dormant there (no window server, no Spotify/Music side-effects).
            guard !isRenderingPreview else { return }
            syncPill()
            // Media pause/resume hangs off the recording edge: every way a take
            // starts or ends (finish, cancel, max-length watchdog) crosses it,
            // and a failed start never enters .recording, so no resume is owed.
            if phase.isRecording != oldValue.isRecording {
                if phase.isRecording {
                    mediaPause.dictationDidStart(pauseEnabled: settings.pauseMediaWhileDictating)
                } else {
                    mediaPause.dictationDidEnd()
                }
            }
        }
    }
    var audioLevel: Float = 0

    // MARK: - Screenshot rendering (off-screen documentation only)
    // Written only by ScreenshotRenderer, which is itself debug-only. In release
    // these collapse to compile-time constants, so the `phase` guard below and
    // the pill's preview branches fold away instead of costing anything on the
    // hot path of every state change.
    #if DEBUG
    /// When true, `phase` changes skip the live floating panel and media-pause
    /// side-effects so the pill views can be rasterised head­lessly. Never set
    /// in normal operation.
    @ObservationIgnored var isRenderingPreview = false
    /// A fixed waveform for off-screen renders. The live meter is fed by audio
    /// callbacks that never fire during rasterisation, so the pill would show a
    /// flat bar otherwise; `nil` in normal operation (the live meter is used).
    @ObservationIgnored var previewWaveform: [Float]?
    /// Drives the transcribing spinner's rotation per frame for off-screen
    /// renders (the system `ProgressView` can't animate under `ImageRenderer`);
    /// `nil` in normal operation (the real spinner is used).
    @ObservationIgnored var previewSpinnerAngle: Double?
    #else
    var isRenderingPreview: Bool { false }
    var previewWaveform: [Float]? { nil }
    var previewSpinnerAngle: Double? { nil }
    #endif

    var fnMonitorActive = false
    /// User-toggled pause: tears down the fn listener so the key is free for
    /// other uses (gaming, screen-sharing), without quitting Shout.
    var isPaused = false
    /// The transcript shown in the pill as immediate "here's what I heard"
    /// feedback while the (slower) rewrite runs, and — with live preview on —
    /// refined as you speak. Empty when there's nothing to preview.
    var transcriptPreview = ""
    /// Bumps whenever an interim pass recognizes *new* words, independent of the
    /// live-preview toggle. A voice-activity signal for the pill: a talker too
    /// quiet to cross the mic-energy floor is still clearly active if words are
    /// landing. Only meaningful while interim passes run (see startStreamingPreview).
    private(set) var interimSpeechTick = 0
    /// The take's profile-switch decision: live-latched while recording,
    /// frozen at key release. The pill renders it and the pipeline applies it
    /// — one value, so the display and the outcome cannot disagree (see
    /// `VoiceSwitchDecision` for the contract).
    var voiceDecision = VoiceSwitchDecision()
    /// Set once the frozen head audio has been classified — nothing new can
    /// arrive for the decision, so head decodes stop.
    @ObservationIgnored private var headClassificationDone = false

    /// True while recording once the switch trigger is heard and the user is
    /// still choosing — or has named something that matches nothing — so the
    /// pill expands into the scannable profile list (with "isn't on the list"
    /// feedback in the unmatched case).
    var isShowingVoiceProfileList: Bool {
        guard case .recording = phase else { return false }
        switch voiceDecision.state {
        case .awaitingName, .unmatched: return true
        case .inactive, .cancelled, .latched: return false
        }
    }

    /// Whether the floating pill should currently be on screen. Distinct from
    /// `phase`: an unlocked recording only reveals the pill once the press is
    /// committed (held past a short debounce, or locked), so the first quick
    /// tap of a double-tap — and stray single taps — never flash it.
    private(set) var pillVisible = false {
        didSet { if pillVisible != oldValue { pill.refresh() } }
    }
    @ObservationIgnored private var pillShowDebounce: DispatchWorkItem?
    /// A press must last at least this long to be a "hold" worth showing the
    /// pill for. Comfortably above real tap durations (~0.08 s), below the
    /// hold-to-talk threshold.
    private let pillShowDelay: TimeInterval = 0.15

    let settings = SettingsStore()
    let permissions = PermissionsManager()
    let modelManager = ModelManager()
    let modelRegistry = ModelRegistry()
    let profiles = ProfileStore()
    let history = HistoryStore()

    private let recorder = AudioRecorder()
    private let transcriber: any TranscriptionEngine
    private var pipeline: DictationPipeline
    /// The rewrite engine for the active profile's resolved model, cached with the
    /// entry id it was built for and rebuilt only when the selection changes. What
    /// this saves is engine *construction* — for the on-device backend that means
    /// holding one `SystemLanguageModel` rather than building one per dictation.
    /// It does not preserve a warmed session: each rewrite deliberately gets a
    /// fresh one so dictations can't bleed into each other's context.
    private var cachedRewriter: (any RewriteEngine)?
    private var cachedEntryID: String?
    /// Set by `rewriteResolution` when the current dictation began with a voice
    /// switch command, for the pipeline runner to confirm and maybe persist.
    private var pendingVoiceSwitch: (id: String, name: String, persist: Bool)?
    /// Set by `rewriteResolution` when a voice command failed or was cancelled
    /// with nothing to insert, for the pipeline runner to surface at the end.
    private var pendingVoiceFeedback: (message: String, kind: NoticeKind)?
    private let inserter = TextInserter()
    private let fnMonitor = FnKeyMonitor()
    private let mediaPause = MediaPauseCoordinator(control: AppleScriptMediaControl())

    /// Engines are injected (defaulting to the configured backends) so tests can
    /// substitute fakes and swapping a model is a change in `EngineFactory`, not
    /// here. Nothing in this file names a concrete engine type.
    init(transcriber: (any TranscriptionEngine)? = nil) {
        let t = transcriber ?? EngineFactory.makeTranscriber(modelURL: modelManager.modelPath)
        self.transcriber = t
        self.pipeline = DictationPipeline(transcriber: t)
    }

    @ObservationIgnored private(set) lazy var windows = WindowManager(appState: self)
    @ObservationIgnored private(set) lazy var pill = PillController(appState: self)

    // Gesture bookkeeping
    private let gestures = FnGestureRecognizer()
    private var tapExpiry: DispatchWorkItem?
    private var noticeExpiry: DispatchWorkItem?
    private var monitorRetryTimer: Timer?
    @ObservationIgnored private var activityToken: NSObjectProtocol?
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    /// Last interim transcript seen, to tell "new words landed" from "same
    /// trailing window re-transcribed" when bumping `interimSpeechTick`.
    @ObservationIgnored private var lastInterimText = ""
    /// The app that was frontmost when the current dictation began — where the
    /// result is pasted, even if focus drifts during the (slow) pipeline.
    @ObservationIgnored private var dictationTarget: TextInserter.Target?
    @ObservationIgnored private var recordingWatchdog: DispatchWorkItem?
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    /// One VoiceOver announcement per recording for the unmatched state — the
    /// interim classifier re-fires every pass, and repeating the message each
    /// pass would drown the user.
    @ObservationIgnored private var announcedUnmatched = false
    /// The audible cues for voice-profile switching (rising "name a profile" /
    /// falling "locked in") and the silence-gated timing of the prompt cue.
    /// Owns its own sound players and voice-activity tracker — see
    /// `VoiceCueController`.
    @ObservationIgnored private let voiceCues = VoiceCueController()

    /// A created tap is NOT enough: without the Input Monitoring grant macOS
    /// still lets the tap exist (via Accessibility) but only delivers events
    /// aimed at Shout itself — the fn key then works solely while a Shout
    /// window is focused. Global operation needs both.
    var fnGloballyActive: Bool {
        fnMonitorActive && permissions.inputMonitoringGranted
    }

    var needsSetup: Bool {
        !permissions.micGranted || !permissions.accessibilityGranted
            || !fnGloballyActive || modelManager.state != .ready
    }

    var menuBarSymbol: String {
        if isPaused { return "pause.circle" }
        if case .downloading = modelManager.state { return "arrow.down.circle" }
        switch phase {
        case .idle: return "megaphone"
        case .recording: return "megaphone.fill"
        case .transcribing, .rewriting: return "waveform"
        // SF Symbols has no megaphone.slash, so failures borrow the mic metaphor.
        case .notice(_, let kind, _): return kind == .failure ? "mic.slash" : "megaphone"
        }
    }

    var statusLine: String {
        if isPaused { return "Paused — dictation off" }
        switch modelManager.state {
        case .ready: break
        case .downloading(let p): return "Downloading speech model… \(Int(p * 100))%"
        case .failed: return "Speech model download failed — open Setup"
        case .missing: return "Speech model not installed — open Setup"
        }
        if !permissions.micGranted || !permissions.accessibilityGranted {
            return "Permissions missing — open Setup"
        }
        if fnMonitorActive && !permissions.inputMonitoringGranted {
            return "fn works only inside Shout — open Setup"
        }
        if !fnMonitorActive { return "Fn key inactive — open Setup" }
        switch phase {
        case .idle: return "Ready — hold fn and speak"
        case .recording(let locked): return locked ? "Recording (hands-free)" : "Recording…"
        case .transcribing: return "Transcribing…"
        case .rewriting: return "Polishing…"
        case .notice(let message, _, _): return message
        }
    }

    // MARK: - Lifecycle

    func startUp() {
        // Opt out of App Nap: a napped process misses the event tap's latency
        // budget and macOS silently disables the tap — the fn key then only
        // works while a window keeps the app visible.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Listening for the fn dictation key")

        permissions.refresh()
        modelManager.refresh()

        recorder.onLevel = { [weak self] level in
            self?.audioLevel = level
            self?.voiceCues.feed(level: level, at: .now)
        }
        fnMonitor.handler = { [weak self] event in self?.handleFnEvent(event) }
        // Attempt the tap even before the permission is granted: the failed
        // attempt is what makes macOS register Shout under
        // Privacy & Security › Input Monitoring in the first place.
        fnMonitorActive = fnMonitor.start()
        if !permissions.inputMonitoringGranted {
            // Also register via the request API (shows no dialog for this
            // service) so Shout reliably appears in the Settings list even
            // when tap creation succeeded through Accessibility alone.
            permissions.requestInputMonitoring()
        }

        // Retry the event tap until Input Monitoring is granted, and keep
        // permission state fresh for the UI. Deliberately never invalidated, and
        // the activity token above is never ended: both are owned by the single
        // process-lifetime AppState, and the fn tap must keep working — and keep
        // being revived — for exactly as long as Shout runs. macOS reclaims both
        // at exit. The closure holds `self` weakly regardless.
        monitorRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                if self.fnMonitorActive {
                    // Watchdog: revive the tap if the system disabled it.
                    self.fnMonitor.ensureEnabled()
                } else {
                    // Creating the tap is the only LIVE permission probe: the
                    // preflight API stays frozen-false for the whole process
                    // lifetime even after the user grants access.
                    self.permissions.refresh()
                    self.attemptFnMonitorStart()
                }
            }
        }

        prewarm()

        if needsSetup || !settings.onboardingCompleted {
            windows.showOnboarding()
        }
    }

    private func attemptFnMonitorStart() {
        guard !fnMonitorActive else { return }
        fnMonitorActive = fnMonitor.start()
    }

    /// Input Monitoring has no system pop-up: request access (registers the
    /// app with TCC), retry the tap, and if that still fails take the user
    /// straight to the System Settings list.
    func requestInputMonitoring() {
        permissions.requestInputMonitoring()
        attemptFnMonitorStart()
        if !fnMonitorActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.fnMonitorActive else { return }
                self.permissions.openInputMonitoringSettings()
            }
        }
    }

    /// Relaunches the app (needed after macOS grants Input Monitoring).
    func restartApp() {
        // Relaunch shortly after we exit. The bundle path is passed as $0 rather
        // than interpolated into the script, so a path containing shell
        // metacharacters can't be executed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.8; exec /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Pause/resume the global fn listener. Paused frees the fn key for other
    /// uses without quitting; the retry watchdog also stands down while paused.
    func togglePause() {
        isPaused.toggle()
        if isPaused {
            fnMonitor.stop()
            fnMonitorActive = false
            announce("Shout paused")
        } else {
            fnMonitorActive = fnMonitor.start()
            announce("Shout resumed")
        }
    }

    /// Speaks a short status change for VoiceOver users — the pill is a
    /// non-interactive overlay outside the accessibility tree, so state changes
    /// would otherwise be silent.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// The profile this take will run: the latched voice-switch target while
    /// one is shown, else the active selection. What the pill's leading glyph
    /// displays, so the icon and the outcome cannot disagree.
    var effectiveProfile: Profile {
        if case .latched(let id, _) = voiceDecision.state,
           let matched = profiles.profile(id: id) { return matched }
        return profiles.active
    }

    /// The model entry the active profile resolves to: its own override, else
    /// the registry default.
    var activeEntry: ModelEntry { entry(for: profiles.active) }

    /// True when this take's rewrite would run off the machine — the effective
    /// profile (a latched voice switch included) resolves to a non-local
    /// endpoint. Drives the pill's "leaving your Mac" indicator; only meaningful
    /// while polishing is on, since otherwise no rewrite runs.
    var effectiveIsRemote: Bool {
        settings.rewriteEnabled && !entry(for: effectiveProfile).isLocal
    }

    /// The model entry a profile resolves to: its own override, else the default.
    private func entry(for profile: Profile) -> ModelEntry {
        modelRegistry.entry(id: profile.modelID ?? modelRegistry.defaultID) ?? .appleFoundation
    }

    /// Availability of the engine the active profile will use — for Settings to
    /// show a warning. A throwaway engine; reading availability is cheap and needs
    /// neither the API key nor any warm-up.
    var activeRewriteAvailability: EngineAvailability {
        EngineFactory.makeRewriter(for: activeEntry, allowInsecureHTTP: settings.allowInsecureHTTP).availability
    }

    /// The engine for a profile's model, reused across dictations while the
    /// resolved selection is unchanged (see `cachedRewriter`).
    private func rewriteEngine(for profile: Profile) -> any RewriteEngine {
        let entry = entry(for: profile)
        if cachedEntryID == entry.id, let engine = cachedRewriter { return engine }
        let engine = EngineFactory.makeRewriter(
            for: entry, apiKey: modelRegistry.apiKey(for: entry.id),
            allowInsecureHTTP: settings.allowInsecureHTTP)
        cachedRewriter = engine
        cachedEntryID = entry.id
        return engine
    }

    private func rewriteEngine() -> any RewriteEngine { rewriteEngine(for: profiles.active) }

    /// Maps the frozen live decision onto what to process: the (possibly
    /// command-stripped) final text plus the profile/engine to run. Selection
    /// already happened, live, while recording — whatever the pill showed at
    /// key release runs, in both directions: a latched profile runs even if
    /// the final decode garbled the command (the transcript is consulted only
    /// to locate the strip boundary), and without a latch nothing switches
    /// even when the final transcript plainly contains a command — acting on
    /// words the pill never confirmed is exactly the surprise this forbids.
    private func rewriteResolution(for raw: String) -> RewriteResolution {
        pendingVoiceSwitch = nil
        pendingVoiceFeedback = nil
        if settings.voiceProfileSwitch,
           !settings.voiceSwitchTrigger.trimmingCharacters(in: .whitespaces).isEmpty,
           voiceDecision.state != .inactive {
            let outcome = voiceDecision.releaseOutcome(
                transcript: raw, trigger: settings.voiceSwitchTrigger,
                cancelWords: VoiceCommand.phraseList(settings.voiceSwitchCancelWords),
                profiles: profiles.profiles.map { (id: $0.id, name: $0.name) })
            switch outcome {
            case .dictation:
                break
            case .switched(let id, _, let content):
                // The badge's target can only vanish if the profile list was
                // edited mid-take — say so instead of silently reneging.
                guard let matched = profiles.profile(id: id) else {
                    pendingVoiceFeedback = (
                        message: "That profile is gone — kept \(profiles.active.name)",
                        kind: .failure)
                    return RewriteResolution(
                        text: content,
                        step: content.isEmpty ? nil : RewriteStep(engine: rewriteEngine(), profile: profiles.active))
                }
                pendingVoiceSwitch = (matched.id, matched.name,
                                      settings.voiceSwitchSticky || content.isEmpty)
                return RewriteResolution(
                    text: content,
                    step: RewriteStep(engine: rewriteEngine(for: matched), profile: matched))
            case .kept(let content, let notice):
                switch notice {
                case .cancelled:
                    pendingVoiceFeedback = (message: "Cancelled", kind: .info)
                case .releasedEarly:
                    pendingVoiceFeedback = (
                        message: "Released before a profile was chosen — kept \(profiles.active.name)",
                        kind: .failure)
                case .unknownName(let spoken):
                    pendingVoiceFeedback = (
                        message: "No profile called “\(spoken)” — kept \(profiles.active.name)",
                        kind: .failure)
                case nil:
                    break
                }
                return RewriteResolution(
                    text: content,
                    step: content.isEmpty ? nil : RewriteStep(engine: rewriteEngine(), profile: profiles.active))
            }
        }
        return RewriteResolution(
            text: raw,
            step: RewriteStep(engine: rewriteEngine(), profile: profiles.active))
    }

    /// Warms the active profile's engine with the exact instructions its next
    /// rewrite will use, so the first call after a change isn't cold.
    private func prewarmRewrite() {
        guard settings.rewriteEnabled else { return }
        let engine = rewriteEngine()
        guard engine.isAvailable else { return }
        let prompt = profiles.active.buildPrompt(transcript: "", languageCode: nil, glossary: settings.glossary)
        engine.prewarm(instructions: prompt.system)
    }

    /// Loads the Whisper model and warms the active rewrite engine in the
    /// background so the first dictation is fast.
    func prewarm() {
        if case .ready = modelManager.state, !transcriber.isReady {
            Task.detached(priority: .utility) { [transcriber] in
                try? await transcriber.prepare()
            }
        }
        prewarmRewrite()
    }

    /// Drops the cached engine and re-warms. Called after the user changes the
    /// default model, switches the active profile, or edits a profile/endpoint,
    /// so the change takes effect without a relaunch.
    func reconfigureRewrite() {
        cachedRewriter = nil
        cachedEntryID = nil
        prewarmRewrite()
    }

    // MARK: - Fn gesture state machine

    private func handleFnEvent(_ event: FnEvent) {
        // Esc during the pipeline aborts it — not a recording gesture, so it's
        // handled here rather than in the pure recognizer.
        if case .escapePressed = event, phase.isBusy {
            cancelPipeline()
            return
        }
        let config = FnGestureConfig(
            holdThreshold: settings.holdThreshold, doubleTapWindow: settings.doubleTapWindow)
        let intents = gestures.handle(
            event, recording: fnRecordingState, isFnDown: fnMonitor.isFnDown, config: config)
        for intent in intents { apply(intent) }
    }

    /// Maps the app phase onto what the gesture recognizer needs. `.idle` covers
    /// both idle and the transient notice phase, so a gesture within ~2 s after
    /// an insertion isn't swallowed while the "Inserted" pill still shows.
    private var fnRecordingState: FnRecordingState {
        switch phase {
        case .idle, .notice: return .idle
        case .recording(let locked): return locked ? .recordingLocked : .recordingUnlocked
        case .transcribing, .rewriting: return .busy
        }
    }

    private func apply(_ intent: FnGestureIntent) {
        switch intent {
        case .begin: beginRecording()
        case .lock: phase = .recording(locked: true)
        case .finish: finishRecording()
        case .cancel: cancelRecording()
        case .armDoubleTap: scheduleDoubleTapTimeout()
        case .disarmDoubleTap: tapExpiry?.cancel()
        }
    }

    private func scheduleDoubleTapTimeout() {
        tapExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for intent in self.gestures.doubleTapTimedOut() { self.apply(intent) }
        }
        tapExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.doubleTapWindow, execute: work)
    }

    // MARK: - Recording control

    func toggleDictation() {
        switch phase {
        case .idle, .notice:
            beginRecording()
            if phase.isRecording {
                phase = .recording(locked: true)
            }
        case .recording:
            gestures.reset()
            tapExpiry?.cancel()
            finishRecording()
        default:
            break
        }
    }

    /// Drives pill visibility from the current phase, applying the commit
    /// debounce for unlocked recordings.
    private func syncPill() {
        switch phase {
        case .idle:
            pillShowDebounce?.cancel()
            pillVisible = false
        case .recording(let locked):
            if locked {
                // Hands-free engaged — reveal immediately.
                pillShowDebounce?.cancel()
                pillVisible = true
            } else if !pillVisible {
                // Unlocked: could be a hold starting or the first tap of a
                // double-tap. Wait out the debounce and only show if the key is
                // still physically held (a real hold, not a released tap).
                schedulePillDebounce()
            }
        case .transcribing, .rewriting, .notice:
            pillShowDebounce?.cancel()
            pillVisible = true
        }
        // Re-evaluate even if `pillVisible` didn't change so the panel's
        // geometry tracks the current style.
        pill.refresh()
    }

    private func schedulePillDebounce() {
        pillShowDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .recording(false) = self.phase, self.fnMonitor.isFnDown {
                self.pillVisible = true
            }
        }
        pillShowDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pillShowDelay, execute: work)
    }

    private func beginRecording() {
        guard case .ready = modelManager.state else {
            setNotice("Speech model missing — open Setup", kind: .failure)
            windows.showOnboarding()
            return
        }
        guard permissions.micGranted else {
            setNotice("Microphone permission needed", kind: .failure)
            windows.showOnboarding()
            return
        }
        noticeExpiry?.cancel()
        transcriptPreview = ""
        lastInterimText = ""
        voiceDecision = VoiceSwitchDecision()
        headClassificationDone = false
        announcedUnmatched = false
        voiceCues.beginTake()
        // Capture the paste target now, while the user's app is still frontmost.
        dictationTarget = TextInserter.currentTarget()
        do {
            try recorder.start()
            phase = .recording(locked: false)
            announce("Listening")
            // Warm the on-device rewrite model now, while the user is still
            // speaking. The launch-time prewarm goes cold after idle, so a
            // dictation hours later would otherwise pay AFM cold-start latency
            // at the very end; overlapping it with speech hides that cost.
            prewarmRewrite()
            startStreamingPreview()
            scheduleRecordingWatchdog()
        } catch {
            setNotice("Could not start microphone", kind: .failure)
        }
    }

    /// Auto-finish a recording that has run to the maximum length — a walk-away
    /// hands-free session or a physically stuck fn key — so the in-memory audio
    /// buffer can't grow without bound.
    private func scheduleRecordingWatchdog() {
        recordingWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase.isRecording else { return }
            Log.app.notice("Recording reached max length; finishing automatically")
            self.finishRecording()
        }
        recordingWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.maxDictationDuration, execute: work)
    }

    // MARK: - Live preview

    /// While recording, run interim transcription passes that drive the live
    /// pill: the profile-switch decision (classifying the utterance head) and,
    /// when enabled, the live transcript preview (trailing window). The text
    /// shown is a throwaway preview; the inserted content still comes from the
    /// single full-buffer pass on release — but the profile DECISION made here
    /// is final (see `VoiceSwitchDecision`). The loop stops early once there
    /// is nothing left to drive (preview off, decision latched or head
    /// exhausted).
    private func startStreamingPreview() {
        guard settings.livePreview || settings.voiceProfileSwitch else { return }
        let language = settings.languageMode
        let glossary = transcriptionGlossary()
        streamingTask?.cancel()
        streamingTask = Task { @MainActor [weak self] in
            var shownOnce = false
            while !Task.isCancelled {
                guard let self, self.settings.livePreview || self.needsCommandClassification
                else { return }
                // Badge latency is the whole game while the user is choosing
                // from the list; otherwise get the first words up fast, then
                // ease off to keep interim passes from monopolizing the GPU.
                let choosing: Bool
                switch self.voiceDecision.state {
                case .awaitingName, .unmatched: choosing = true
                default: choosing = false
                }
                let interval: UInt64 = choosing ? 250_000_000
                    : shownOnce ? 600_000_000 : 200_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                if await self.updateInterimPreview(language: language, glossary: glossary) {
                    shownOnce = true
                }
            }
        }
    }

    /// Whether interim passes still need to classify the utterance head: the
    /// feature is on, nothing latched, and the frozen head hasn't had its
    /// final classification yet.
    private var needsCommandClassification: Bool {
        settings.voiceProfileSwitch && !voiceDecision.isLatched && !headClassificationDone
    }

    /// Runs one interim pass. Returns whether the pill was updated.
    @discardableResult
    private func updateInterimPreview(language: LanguageMode, glossary: [String]) async -> Bool {
        guard phase.isRecording, transcriber.isReady else { return false }
        let rate = AudioRecorder.targetSampleRate
        let headWindow = Int(rate * Tuning.voiceCommandHeadSeconds)
        let tailWindow = Int(rate * Tuning.previewWindowSeconds)
        // Ask only for the windows this pass can actually use, so nothing copies
        // audio it won't decode. Never take a whole-buffer snapshot: that would
        // push a multi-megabyte copy onto the audio render thread — see
        // AudioRecorder.windows(head:tail:).
        let audio = recorder.windows(
            head: needsCommandClassification ? headWindow : 0,
            tail: settings.livePreview ? tailWindow : 0)
        // As little as ~0.4 s is enough to show first words; the silence/
        // hallucination guards in the transcriber drop empty fragments.
        guard audio.totalCount >= Int(rate * Tuning.previewMinSeconds) else { return false }

        // Below both caps the head and tail clips are the same audio — the
        // common case — so a single decode serves both consumers.
        let whole = audio.totalCount <= min(headWindow, tailWindow)

        var headText: String?
        if needsCommandClassification {
            // The command grammar only matches at the utterance start, so the
            // decision reads a decode of the head. Once the take outgrows the
            // window the head audio is frozen and this pass is the last word.
            let result = try? await transcriber.transcribe(
                samples: audio.head, language: language, glossary: glossary)
            // Drop results that land after the key was released — the decision
            // froze at key-up and must not move.
            guard phase.isRecording else { return false }
            if let text = result?.text, !text.isEmpty {
                headText = text
                applyLiveClassification(text)
                if audio.totalCount >= headWindow { headClassificationDone = true }
            }
        }

        // The preview shows the most recent words, so it trails the take; the
        // head decode doubles as the preview while the take fits the window.
        let interimText: String?
        if settings.livePreview, !whole || headText == nil {
            let result = try? await transcriber.transcribe(
                samples: audio.tail, language: language, glossary: glossary)
            guard phase.isRecording else { return false }
            interimText = result?.text
        } else {
            interimText = headText
        }
        guard let interimText, !interimText.isEmpty else { return false }

        // Growth (not mere non-emptiness) means the user is actively speaking:
        // during a pause the same window keeps yielding the same text.
        if interimText != lastInterimText {
            lastInterimText = interimText
            interimSpeechTick &+= 1
        }
        // Show the live transcript only when that display option is on. Same
        // glossary/filler cleanup the final text gets, so it reads correctly.
        if settings.livePreview {
            transcriptPreview = TextNormalizer.normalize(interimText, glossary: glossary)
        }
        return true
    }

    /// Feeds one head-decode classification into the take's decision and plays
    /// the confirmation moment when it latches: the badge is the contract, the
    /// tick says "locked in" without needing a glance at the pill, and
    /// VoiceOver users are told outright.
    private func applyLiveClassification(_ headText: String) {
        let list = profiles.profiles.map { (id: $0.id, name: $0.name) }
        let justLatched = voiceDecision.apply(VoiceCommand.classifyPrefix(
            transcript: headText, trigger: settings.voiceSwitchTrigger,
            cancelWords: VoiceCommand.phraseList(settings.voiceSwitchCancelWords),
            profiles: list))
        if justLatched, case .latched(_, let name) = voiceDecision.state {
            voiceCues.playLatchChime()
            announce("Using \(name)")
        }
        if case .unmatched(let spoken) = voiceDecision.state, !announcedUnmatched {
            announcedUnmatched = true
            announce("\(spoken) isn’t on the profile list — say a name, a number, or cancel")
        }
        switch voiceDecision.state {
        case .awaitingName, .unmatched:
            voiceCues.schedulePromptChime(isListVisible: { [weak self] in
                self?.isShowingVoiceProfileList ?? false
            })
        case .inactive, .cancelled, .latched:
            voiceCues.cancelPromptChime()
        }
    }

    /// The glossary used for transcription, silently augmented with the
    /// voice-switch command vocabulary — trigger phrase, cancel words, and
    /// profile names — so Whisper transcribes it consistently. The live
    /// decision hangs on the head decode hearing the name exactly, and the
    /// final decode stripping those same words. Not shown in the user's
    /// glossary and never persisted.
    private func transcriptionGlossary() -> [String] {
        guard settings.voiceProfileSwitch else { return settings.glossary }
        var extra: [String] = []
        let trigger = settings.voiceSwitchTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trigger.isEmpty, !settings.glossary.contains(trigger) { extra.append(trigger) }
        for word in VoiceCommand.phraseList(settings.voiceSwitchCancelWords)
        where !settings.glossary.contains(word) && !extra.contains(word) {
            extra.append(word)
        }
        for profile in profiles.profiles
        where !settings.glossary.contains(profile.name) && !extra.contains(profile.name) {
            extra.append(profile.name)
        }
        return settings.glossary + extra
    }

    private func stopStreamingPreview() {
        streamingTask?.cancel()
        streamingTask = nil
        // The take is over; a prompt cue still pending must not beep into
        // whatever the pill shows next.
        voiceCues.cancelPromptChime()
    }

    private func cancelRecording() {
        gestures.reset()
        tapExpiry?.cancel()
        recordingWatchdog?.cancel()
        stopStreamingPreview()
        recorder.cancel()
        audioLevel = 0
        phase = .idle
    }

    private func finishRecording() {
        // Key release is the contract point: whatever the pill shows now is
        // what runs. Freeze before anything else so no in-flight interim pass
        // can move the decision.
        voiceDecision.freeze()
        gestures.reset()
        tapExpiry?.cancel()
        recordingWatchdog?.cancel()
        stopStreamingPreview()
        let samples = recorder.stop()
        audioLevel = 0
        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        guard duration >= Tuning.minDictationDuration else {
            phase = .idle
            return
        }
        phase = .transcribing
        let language = settings.languageMode
        let glossary = transcriptionGlossary()
        pipelineTask = Task { [weak self] in
            await self?.runPipeline(samples: samples, duration: duration,
                                    language: language, glossary: glossary)
        }
    }

    /// Aborts an in-flight transcribe/rewrite (Esc while busy). Whisper itself
    /// isn't interruptible mid-pass, but the pipeline bails at the next await and
    /// never inserts.
    private func cancelPipeline() {
        pipelineTask?.cancel()
        pipelineTask = nil
        setNotice("Cancelled", kind: .info)
    }

    // MARK: - Pipeline

    private func runPipeline(
        samples: [Float],
        duration: Double,
        language: LanguageMode,
        glossary: [String]
    ) async {
        do {
            pendingVoiceSwitch = nil
            pendingVoiceFeedback = nil
            let result = try await pipeline.run(
                samples: samples, language: language, glossary: glossary,
                rewriteEnabled: settings.rewriteEnabled, minWords: settings.minWordsForRewrite,
                resolve: { [weak self] raw in
                    self?.rewriteResolution(for: raw) ?? RewriteResolution(text: raw, step: nil)
                },
                onTranscribed: { [weak self] preview in self?.transcriptPreview = preview },
                onRewriting: { [weak self] in self?.phase = .rewriting })
            guard let result else {
                setNotice("Didn’t catch anything", kind: .info)
                return
            }
            if Task.isCancelled { return }

            // A leading "use profile …" command switched the profile for this
            // dictation; persist it for later ones when sticky or content-free.
            let switched = pendingVoiceSwitch
            if let switched, switched.persist, profiles.activeID != switched.id {
                profiles.activeID = switched.id
                reconfigureRewrite()
            }

            // Let the pill's last frame match exactly what gets pasted.
            transcriptPreview = result.final

            // A content-free command inserts nothing — confirm the switch, or
            // explain the failed/cancelled attempt.
            if result.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let feedback = pendingVoiceFeedback {
                    setNotice(feedback.message, kind: feedback.kind, duration: 3)
                } else if let switched {
                    // Switch confirmations run longer than the 1.6 s default:
                    // a profile name takes longer to read than a checkmark.
                    setNotice("Switched to \(switched.name)", kind: .success,
                              glyph: profiles.profile(id: switched.id)?.glyph, duration: 3)
                } else {
                    setNotice("Didn’t catch anything", kind: .info)
                }
                return
            }

            let outcome = await inserter.insert(
                result.final, restoreClipboard: settings.restoreClipboard, target: dictationTarget)
            if settings.saveHistory {
                history.add(HistoryEntry(
                    id: UUID(),
                    date: Date(),
                    raw: result.raw,
                    cleaned: result.final,
                    language: result.languageCode,
                    appName: dictationTarget?.name ?? "Unknown",
                    duration: duration,
                    rewritten: result.rewritten
                ))
            }
            switch outcome {
            case .pasted(let target):
                if let feedback = pendingVoiceFeedback {
                    // A failed switch whose text was still inserted: the "kept
                    // the current profile" warning outranks the routine success.
                    setNotice(feedback.message, kind: feedback.kind, duration: 3)
                } else {
                    // Flag when the polish silently fell back to raw, so the user
                    // knows to proofread (the German model can drop content).
                    let base = result.polishFellBack ? "Inserted raw into \(target)" : "Inserted into \(target)"
                    if let switched {
                        setNotice("\(base) · \(switched.name)", kind: .success,
                                  glyph: profiles.profile(id: switched.id)?.glyph, duration: 3)
                    } else {
                        setNotice(base, kind: .success)
                    }
                }
            case .leftOnClipboard(let reason):
                setNotice(reason, kind: .failure, duration: 5)
            }
        } catch is CancellationError {
            // Esc during the pipeline — cancelPipeline() already set the notice.
            return
        } catch {
            setNotice(error.localizedDescription, kind: .failure)
        }
    }

    private func setNotice(_ message: String, kind: NoticeKind, glyph: ProfileGlyph? = nil,
                           duration: TimeInterval = 1.6) {
        phase = .notice(message: message, kind: kind, glyph: glyph)
        announce(message)
        noticeExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, case .notice = self.phase else { return }
            self.phase = .idle
        }
        noticeExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: expiry)
    }
}
