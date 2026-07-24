// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import ShoutCore
import SwiftUI

/// Hosts the floating status pill. A non-activating, click-through panel so it
/// never steals focus from the app being dictated into. The panel is sized and
/// placed per the user's chosen style: a capsule at the bottom centre
/// (classic), or a shape pinned to the very top and centred on the camera notch
/// (dynamic island).
@MainActor
final class PillController {
    private let panel: NSPanel
    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState

        let hosting = NSHostingView(rootView: PillRootView().environment(appState))
        // We drive the panel size ourselves (per style). Without this, the
        // hosting view tries to push the SwiftUI view's `.infinity` frame onto
        // the borderless panel as min/max size extrema, which AppKit rejects
        // during the constraint-update cycle → EXC_BREAKPOINT crash.
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 72)

        panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar // above the menu bar (24), so it can hug the notch
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
    }

    func refresh() {
        if appState.pillVisible {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        configureGeometry()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            // Delivered on the main thread by NSAnimationContext.
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    /// Size and place the panel for the active style. The SwiftUI view then
    /// assumes this canvas: centred content for classic, top-pinned for notch.
    private func configureGeometry() {
        switch appState.settings.pillStyle {
        case .classic:
            guard let screen = NSScreen.main else { return }
            // A fixed, tall-enough canvas: the capsule sizes to content and
            // bottom-aligns, so short states stay compact at the bottom edge
            // while the profile list grows upward without resizing the window.
            let size = NSSize(width: 480, height: 360)
            panel.setContentSize(size)
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))

        case .dynamicIsland:
            guard let screen = NotchMetrics.screen() else { return }
            // A generous canvas pinned flush to the very top, centred on the
            // notch; the island grows within it. Must match the view's pinned
            // root frame so window-size extrema stay constant.
            let size = NotchPillLayout.canvas
            panel.setContentSize(size)
            let frame = screen.frame // full frame — includes the menu-bar/notch band
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height))
        }
    }
}

/// Selects the concrete pill view for the chosen style. The controller sizes
/// the window to match.
struct PillRootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.settings.pillStyle {
        case .classic: PillView()
        case .dynamicIsland: NotchPillView()
        }
    }
}

/// The classic capsule floating at the bottom of the screen.
struct PillView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PillContent()
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            // A capsule for the one-line states; a rounded panel when the pill
            // expands into the profile list.
            .pillSurface(app.isShowingVoiceProfileList
                ? AnyShape(RoundedRectangle(cornerRadius: Theme.pillCornerRadius, style: .continuous))
                : AnyShape(Capsule()))
            // Bottom-aligned in a fixed, tall-enough canvas so the panel grows
            // UPWARD into the list without the window resizing (dynamic resizes
            // are what crash the hosting view).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            // Match the notch island: spring between states instead of snapping.
            .animation(reduceMotion ? nil : Theme.pillAnimation, value: app.phase)
            .animation(reduceMotion ? nil : Theme.pillAnimation, value: app.voiceDecision)
    }
}

/// The phase-dependent innards shared by both pill styles: a live level meter
/// while recording, progress while transcribing/polishing, the outcome notice,
/// and the optional live transcript preview.
struct PillContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels: [Float] = Array(repeating: 0.04, count: 24)

    /// One preview width across every phase, so the live transcript box doesn't
    /// visibly jump when recording hands off to transcribing.
    private static let previewWidth: CGFloat = 340

    /// Hands-free only: whether to surface the "tap fn to finish" stop hint. It
    /// appears once the user has been silent for `stopHintAfter` seconds — the
    /// moment someone who doesn't know the gesture is likely to be stuck — and
    /// hides again the instant they speak. While actively dictating the pill
    /// stays bare (dot + waveform), which is the whole point of the hint being
    /// silence-triggered rather than always on.
    @State private var showStopHint = false
    @State private var lastVoiceActivity: Date = .distantPast
    @State private var hintTicker: Task<Void, Never>? = nil
    /// Adaptive-floor speech detection (see `VoiceActivityTracker`); when a
    /// loud, variable room masks speech, the hint simply arrives late or not
    /// at all — the safe direction for a non-critical affordance.
    @State private var voiceActivity = VoiceActivityTracker()

    /// Silence required before the stop hint appears (hands-free recording only).
    private static let stopHintAfter: TimeInterval = 5

    /// Transcript text to show — only when the live preview is enabled;
    /// otherwise the pill falls back to plain status labels.
    private var previewText: String {
        app.settings.livePreview ? app.transcriptPreview : ""
    }

    var body: some View {
        Group {
            if app.isShowingVoiceProfileList {
                voiceCommandList
            } else {
                HStack(spacing: 10) { content }
            }
        }
        .onChange(of: app.audioLevel) { _, newLevel in
            levels.removeFirst()
            levels.append(newLevel)
            if voiceActivity.feed(level: newLevel, at: .now) { registerVoiceActivity() }
        }
        // Recognized words count as activity too — this catches a talker too
        // quiet to cross the energy floor. Only fires while interim passes run.
        .onChange(of: app.interimSpeechTick) { _, _ in registerVoiceActivity() }
        .onChange(of: app.phase) { _, _ in beginStopHintTracking() }
        .onAppear { beginStopHintTracking() }
        .onDisappear { endStopHintTracking() }
    }

    /// Any evidence the user is still speaking — loud-enough audio or newly
    /// recognized words — pushes the silence deadline out and clears the hint.
    private func registerVoiceActivity() {
        lastVoiceActivity = .now
        if showStopHint {
            withAnimation(Theme.pillAnimation) { showStopHint = false }
        }
    }

    /// Start (or restart) the silence watch that reveals the stop hint. Only
    /// hands-free recording arms it — hold-to-talk ends when the key is
    /// released, so "tap fn to finish" would be misleading there. A single
    /// low-frequency ticker checks elapsed silence; speech resets the clock via
    /// the audio-level watch above, so continuous talking never trips it.
    private func beginStopHintTracking() {
        guard case .recording(let locked) = app.phase, locked else {
            endStopHintTracking()
            return
        }
        lastVoiceActivity = .now
        voiceActivity = VoiceActivityTracker() // re-seed from this take's opening room tone
        if showStopHint { showStopHint = false }
        hintTicker?.cancel()
        hintTicker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled,
                      case .recording(let stillLocked) = app.phase, stillLocked
                else { break }
                let silent = Date.now.timeIntervalSince(lastVoiceActivity) >= Self.stopHintAfter
                if silent != showStopHint {
                    withAnimation(Theme.pillAnimation) { showStopHint = silent }
                }
            }
        }
    }

    private func endStopHintTracking() {
        hintTicker?.cancel()
        hintTicker = nil
        if showStopHint { showStopHint = false }
    }

    /// A scannable, numbered list of profiles, shown while the user has said the
    /// trigger and is choosing one by voice. Numbers double as "say two" targets.
    /// When the spoken words match nothing, the header says so — the recoverable
    /// moment: say a name or number again, or bail out with a cancel word.
    private var voiceCommandList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 8) {
                Circle().fill(Theme.recording).frame(width: 9, height: 9)
                if case .unmatched(let spoken) = app.voiceDecision.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.pillFont)
                        .foregroundStyle(Theme.warning)
                    Text("“\(spoken)” isn’t on the list")
                        .font(Theme.pillFont)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                } else {
                    Text("Say a profile or number…")
                        .font(Theme.pillFont)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                // Capped at nine: the spoken-number vocabulary ends there, and
                // the list must fit the fixed panel canvas.
                ForEach(Array(app.profiles.profiles.prefix(9).enumerated()), id: \.element.id) { index, profile in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(Theme.pillFont)
                            .foregroundStyle(Theme.polish)
                            .frame(width: 14, alignment: .trailing)
                        ProfileGlyphView(glyph: profile.glyph,
                                         font: Theme.pillFont,
                                         fallbackTint: .white.opacity(0.85))
                            .frame(width: 18)
                        Text(profile.name)
                            .font(Theme.pillFont)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                if app.profiles.profiles.count > 9 {
                    Text("…and \(app.profiles.profiles.count - 9) more — say the name")
                        .font(Theme.pillFont)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Text(listFooterHint)
                .font(Theme.pillFont)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// The escape hatch, always visible under the list; after a failed attempt
    /// it becomes the full reprompt.
    private var listFooterHint: String {
        let cancel = VoiceCommand.phraseList(app.settings.voiceSwitchCancelWords).first ?? "cancel"
        if case .unmatched = app.voiceDecision.state {
            return "Say a name or number — or “\(cancel)” to keep dictating"
        }
        return "…or say “\(cancel)” to keep dictating"
    }

    @ViewBuilder
    private var content: some View {
        switch app.phase {
        case .recording(let locked):
            profileChip
            Circle()
                .fill(Theme.recording)
                .frame(width: 9, height: 9)
            waveform
            recordingStatus(locked: locked)
        case .transcribing:
            profileChip
            if let angle = app.previewSpinnerAngle {
                renderSpinner(angle: angle) // off-screen render: ProgressView can't animate
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            latchedProfileBadge
            statusText("Transcribing…", previewMaxWidth: Self.previewWidth)
        case .rewriting:
            profileChip
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.polish)
            latchedProfileBadge
            statusText("Polishing…", previewMaxWidth: Self.previewWidth)
        case .notice(let message, let kind, let glyph):
            if let glyph {
                ProfileGlyphView(glyph: glyph, font: Theme.pillFont, fallbackTint: noticeColor(kind))
            } else {
                Image(systemName: kind.symbol)
                    .foregroundStyle(noticeColor(kind))
            }
            Text(message)
                .font(Theme.pillFont)
                .foregroundStyle(.white)
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    /// The profile in effect for this take, visible for the whole recording →
    /// transcribing → polishing stretch — not just in a fleeting notice. Shows
    /// the latched voice-switch target the moment one is confirmed (matching
    /// the badge), else the active selection. Hidden when polishing is off,
    /// where no profile will touch the text.
    @ViewBuilder
    private var profileChip: some View {
        if app.settings.rewriteEnabled {
            let profile = app.effectiveProfile
            HStack(spacing: 5) {
                ProfileGlyphView(glyph: profile.glyph,
                                 font: Theme.pillFont.weight(.semibold),
                                 fallbackTint: .white)
                    .accessibilityLabel("Profile: \(profile.name)")
                // This take's rewrite runs off the machine: a small, steady
                // cloud in the warning tint marks the one moment text leaves the
                // Mac, so it's never silent — sits with the profile it belongs to.
                if app.effectiveIsRemote {
                    Image(systemName: "cloud")
                        .font(Theme.pillFont)
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Sent to a remote server — leaves your Mac")
                }
            }
        }
    }

    /// The status line. When a live transcript is present it's shown capped and
    /// head-truncated (a fixed width, so it doesn't jitter); otherwise a plain
    /// label sized to its own content. Keeping the cap OFF the label is what
    /// stops "Transcribing…"/"Polishing…" from ballooning to the preview width
    /// when the live preview is off.
    @ViewBuilder
    private func statusText(_ label: String, previewMaxWidth: CGFloat) -> some View {
        if previewText.isEmpty {
            Text(label)
                .font(Theme.pillFont)
                .foregroundStyle(.white)
                .lineLimit(1)
        } else {
            Text(previewText)
                .font(Theme.pillFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: previewMaxWidth, alignment: .trailing)
        }
    }

    /// The latched profile, rendered identically wherever it appears. Once
    /// latched it survives recording → transcribing → polishing, so the last
    /// thing the user saw is visibly the thing that runs — the pill's promise.
    @ViewBuilder
    private var latchedProfileBadge: some View {
        if case .latched(_, let name) = app.voiceDecision.state {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(Theme.polish)
            Text(name)
                .font(Theme.pillFont.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    /// The recording state keeps no permanent label — the red dot and waveform
    /// already say "listening", so the pill stays compact. This slot only shows
    /// something when there's genuinely more to say, in priority order:
    /// a latched profile switch, the live transcript (when enabled), or — for
    /// hands-free recording only — the stop hint once the user has gone quiet.
    @ViewBuilder
    private func recordingStatus(locked: Bool) -> some View {
        // `.awaitingName`/`.unmatched` are handled by the expanded list in
        // `body`; here we cover the latched selection and plain listening.
        if app.voiceDecision.isLatched {
            latchedProfileBadge
        } else if !previewText.isEmpty {
            Text(previewText)
                .font(Theme.pillFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: Self.previewWidth, alignment: .trailing)
        } else if locked && showStopHint {
            Text("Tap fn to finish")
                .font(Theme.pillFont)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .transition(.opacity)
        }
    }

    private func noticeColor(_ kind: AppState.NoticeKind) -> Color {
        switch kind {
        case .success: return Theme.success
        case .failure: return Theme.warning
        case .info: return .white.opacity(0.9)
        }
    }

    /// A hand-drawn stand-in for the system spinner, used only by off-screen
    /// renders (which supply `previewSpinnerAngle`). Eight tapered spokes with a
    /// fading trail, rotated as a whole — matches the small `ProgressView` on
    /// the dark pill closely enough for documentation clips.
    private func renderSpinner(angle: Double) -> some View {
        ZStack {
            ForEach(0 ..< 8, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.2 + 0.8 * Double(i) / 8))
                    .frame(width: 2, height: 4.5)
                    .offset(y: -5)
                    .rotationEffect(.degrees(Double(i) / 8 * 360))
            }
        }
        .frame(width: 15, height: 15)
        .rotationEffect(.degrees(angle))
    }

    private var waveform: some View {
        // Off-screen renders supply a fixed waveform (the live meter's audio
        // callbacks never fire during rasterisation); nil falls back to the
        // live rolling buffer.
        let bars = app.previewWaveform ?? levels
        return HStack(spacing: 2.5) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 5 + CGFloat(min(bars[index], 1)) * 24)
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: levels)
        .frame(height: 32)
    }
}
