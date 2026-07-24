// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import ShoutCore
import SwiftUI

/// Off-screen documentation tooling: rasterises the *real* pill and notch
/// SwiftUI views to PNG so the README can show them without a live capture.
///
/// This session has no window server, so `screencapture` can't photograph the
/// running app; `ImageRenderer` draws the same views into a bitmap in-process
/// instead — identical pixels, no display required. Activated only when the
/// `SHOUT_RENDER_DIR` environment variable is set (see `ShoutMain`), so it never
/// runs in normal use.
///
/// Non-destructive by construction: it neither shows the floating panel nor
/// touches the user's stored preferences. `AppState.isRenderingPreview` gates
/// the `phase` side-effects, and any settings the views need (live preview,
/// rewrite on, active profile) are supplied through the non-persistent
/// NSArgumentDomain — see `render-screenshots.sh` — never by assigning to the
/// `SettingsStore`, whose setters would write to UserDefaults.
@MainActor
enum ScreenshotRenderer {
    /// Renders every scene if `SHOUT_RENDER_DIR` is set. Returns whether it did,
    /// so the entry point can skip launching the normal app.
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        func path(_ v: String) -> URL { URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
        // Animation frames take priority so a single run can target either mode.
        if let dir = env["SHOUT_RENDER_FRAMES"], !dir.isEmpty {
            runFrames(outputDir: path(dir))
            return true
        }
        if let dir = env["SHOUT_RENDER_DIR"], !dir.isEmpty {
            run(outputDir: path(dir))
            return true
        }
        return false
    }

    static func run(outputDir: URL) {
        // Bring AppKit up far enough to resolve fonts and SF Symbols, without
        // starting a run loop or showing anything.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Enable the live-transcript preview for the render only, via the
        // in-memory argument domain (highest priority, never written to disk),
        // so the pill can show its live text without touching the user's saved
        // preferences. Must happen before any `SettingsStore` is constructed.
        var argDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        argDomain["livePreview"] = true
        UserDefaults.standard.setVolatileDomain(argDomain, forName: UserDefaults.argumentDomain)

        for shot in shots() {
            let url = outputDir.appendingPathComponent(shot.name + ".png")
            render(shot.view, scale: 2, to: url)
        }
    }

    // MARK: - Scenes

    private struct Shot {
        let name: String
        let view: AnyView
    }

    /// A natural, voice-like waveform so the recording states don't render as a
    /// flat line (the live meter's audio callbacks never fire off-screen).
    private static let waveform: [Float] = [
        0.16, 0.30, 0.48, 0.34, 0.64, 0.90, 0.60, 0.40, 0.82, 1.0, 0.72, 0.50,
        0.88, 0.62, 0.38, 0.56, 0.80, 0.58, 0.30, 0.46, 0.70, 0.42, 0.24, 0.15,
    ]

    private static func makeState(_ configure: (AppState) -> Void) -> AppState {
        let app = AppState(transcriber: PreviewTranscriber())
        app.isRenderingPreview = true // gate the live panel / media side-effects
        configure(app)
        return app
    }

    private static func shots() -> [Shot] {
        // 1 — Classic capsule, hands-free recording (bare dot + waveform).
        let recording = makeState { app in
            app.transcriptPreview = "" // keep this one clean — no preview text
            app.previewWaveform = waveform
            app.phase = .recording(locked: true)
        }

        // 2 — Classic capsule, the LLM polish pass running.
        let polishing = makeState { app in
            app.transcriptPreview = ""
            app.phase = .rewriting
        }

        // 3 — Classic capsule, the success notice after inserting.
        let inserted = makeState { app in
            app.phase = .notice(message: "Inserted", kind: .success, glyph: nil)
        }

        // 4 — Classic capsule, a spoken profile switch latched mid-take.
        let voiceSwitch = makeState { app in
            app.voiceDecision.apply(
                .matched(profileID: "builtin-summarize", profileName: "Summarize", remainder: ""))
            app.previewWaveform = waveform
            app.phase = .recording(locked: true)
        }

        // 5 — Dynamic Island (notch), recording with a live transcript.
        let notchRecording = makeState { app in
            app.transcriptPreview = "let's ship the beta on Friday and gather feedback over the weekend"
            app.previewWaveform = waveform
            app.phase = .recording(locked: true)
        }

        // 6 — Dynamic Island (notch), the voice profile picker open.
        let notchList = makeState { app in
            app.voiceDecision.apply(.awaitingName)
            app.phase = .recording(locked: true)
        }

        return [
            Shot(name: "pill-classic-recording",
                 view: AnyView(ClassicScene { PillView() }.environment(recording))),
            Shot(name: "pill-classic-polishing",
                 view: AnyView(ClassicScene { PillView() }.environment(polishing))),
            Shot(name: "pill-classic-inserted",
                 view: AnyView(ClassicScene { PillView() }.environment(inserted))),
            Shot(name: "pill-classic-voice-switch",
                 view: AnyView(ClassicScene { PillView() }.environment(voiceSwitch))),
            Shot(name: "pill-notch-recording",
                 view: AnyView(NotchScene { NotchPillView() }.environment(notchRecording))),
            Shot(name: "pill-notch-profile-list",
                 view: AnyView(NotchScene { NotchPillView() }.environment(notchList))),
        ]
    }

    // MARK: - Animation frames

    /// Emits numbered PNG frame sequences (and the two static flow states) for
    /// `scripts/render-recording.sh` to stitch into looping clips. The pill is
    /// posed per frame here — SwiftUI's own animation clock doesn't advance
    /// under `ImageRenderer`, so motion is authored, not captured.
    static func runFrames(outputDir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // One periodic level stream; windowing 24 bars over it reproduces the
        // app's rolling meter and — being periodic — loops seamlessly.
        let stream = waveformStream(count: 72)

        // The classic capsule only, on a transparent canvas. A fixed canvas
        // sized to the widest state (recording) keeps every frame the same
        // size, so the pill sizes to its content and grows/shrinks from the
        // centre — as it does in the app — without the video frame changing.
        // Snug now that there's no shadow to leave room for.
        let canvas = CGSize(width: 252, height: 76)
        func bare(_ app: AppState) -> AnyView {
            AnyView(BarePill().environment(app).frame(width: canvas.width, height: canvas.height))
        }

        // recording — the seamless "listening" loop, also the workflow's opener.
        let recording = makeState { $0.phase = .recording(locked: true) }
        emitWaveform("clip-classic-recording", count: 72, dir: outputDir,
                     app: recording, view: bare(recording), stream: stream, opaque: false)
        // transcribing — the rotating spinner.
        let transcribing = makeState { $0.phase = .transcribing }
        emitSpinner("clip-classic-transcribing", count: 40, dir: outputDir,
                    app: transcribing, view: bare(transcribing), opaque: false)
        // polishing / inserted — static states the workflow cross-dissolves through.
        let polishing = makeState { $0.phase = .rewriting }
        rasterize(bare(polishing), scale: 2, opaque: false,
                  to: outputDir.appendingPathComponent("still-classic-polishing.png"))
        let inserted = makeState { $0.phase = .notice(message: "Inserted", kind: .success, glyph: nil) }
        rasterize(bare(inserted), scale: 2, opaque: false,
                  to: outputDir.appendingPathComponent("still-classic-inserted.png"))

        print("frames written to \(outputDir.path)")
    }

    /// Emits a rotating-spinner sequence for the transcribing state — two full
    /// turns over the segment, driven per frame since the system spinner is
    /// frozen under `ImageRenderer`.
    private static func emitSpinner(_ name: String, count: Int, dir: URL, app: AppState, view: AnyView,
                                    opaque: Bool = true) {
        let seg = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: seg, withIntermediateDirectories: true)
        for f in 0 ..< count {
            app.previewSpinnerAngle = Double(f) / Double(count) * 720
            rasterize(view, scale: 2, opaque: opaque,
                      to: seg.appendingPathComponent(String(format: "frame_%04d.png", f)))
        }
        print("✓ \(name)  \(count) frames")
    }

    private static func emitWaveform(_ name: String, count: Int, dir: URL,
                                     app: AppState, view: AnyView, stream: [Float],
                                     opaque: Bool = true) {
        let seg = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: seg, withIntermediateDirectories: true)
        for f in 0 ..< count {
            app.previewWaveform = window(stream, endingAt: f, bars: 24)
            rasterize(view, scale: 2, opaque: opaque,
                      to: seg.appendingPathComponent(String(format: "frame_%04d.png", f)))
        }
        print("✓ \(name)  \(count) frames")
    }

    /// A periodic, speech-like level stream in [0.05, 1]. Integer harmonics make
    /// the period exactly `count`, so a window over it loops without a seam.
    private static func waveformStream(count: Int) -> [Float] {
        (0 ..< count).map { i in
            let t = Double(i) / Double(count)
            let swell = 0.55 + 0.45 * sin(2 * .pi * (t - 0.25)) // slow speech envelope
            let burst = 0.5 + 0.5 * sin(2 * .pi * 3 * t) // syllable-rate bursts
            let detail = 0.5 + 0.5 * sin(2 * .pi * 7 * t + 1.0) // fine texture
            let v = 0.1 + swell * (0.55 * burst + 0.3 * detail)
            return Float(min(max(v, 0.05), 1.0))
        }
    }

    /// The `bars` most recent samples ending at frame `f`, wrapping around — the
    /// rolling window the live pill shows.
    private static func window(_ stream: [Float], endingAt f: Int, bars: Int) -> [Float] {
        let n = stream.count
        return (0 ..< bars).map { k in stream[((f - (bars - 1) + k) % n + n) % n] }
    }

    // MARK: - Rasterisation

    private static func render(_ view: some View, scale: CGFloat, to url: URL) {
        if rasterize(view, scale: scale, to: url) {
            print("✓ \(url.lastPathComponent)")
        }
    }

    @discardableResult
    private static func rasterize(_ view: some View, scale: CGFloat, opaque: Bool = true,
                                  to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = opaque
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("✗ render failed: \(url.lastPathComponent)\n".utf8))
            return false
        }
        do {
            try data.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("✗ write failed: \(error)\n".utf8))
            return false
        }
    }
}

// MARK: - Backdrops

/// A calm, macOS-like desktop gradient so the dark pill reads as floating over a
/// real screen rather than sitting on a flat swatch.
private struct DesktopBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.30, green: 0.26, blue: 0.52),
                Color(red: 0.22, green: 0.36, blue: 0.60),
                Color(red: 0.15, green: 0.44, blue: 0.56),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [.white.opacity(0.18), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 520))
    }
}

/// A faux menu bar so the notch pill reads as hanging from the top of the
/// display. Purely decorative context for the screenshot.
private struct MenuBarStrip: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("Shout").fontWeight(.semibold)
            Text("File").opacity(0.85)
            Text("Edit").opacity(0.85)
            Text("View").opacity(0.85)
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75")
            Text("Fri 9:41")
        }
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.black.opacity(0.18))
    }
}

/// Just the pill — no backdrop and no drop shadow: the real `PillContent` in
/// the shared capsule fill + hairline (`pillSurface` minus its `.shadow`),
/// rendered on a clear canvas for a flat, background-free asset that composites
/// anywhere. The app's own pill keeps its shadow (via `pillSurface`); only this
/// exported asset drops it.
private struct BarePill: View {
    var body: some View {
        PillContent()
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(Capsule().fill(Theme.pillFill))
            .overlay(Capsule().stroke(Theme.pillStroke, lineWidth: Theme.pillStrokeWidth))
            .colorScheme(.dark)
    }
}

/// Frames the classic capsule near the bottom of a desktop, as it floats in use.
private struct ClassicScene<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            DesktopBackdrop()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 26)
        }
        .frame(width: 600, height: 190)
    }
}

/// Frames the notch island at the top-centre, under a faux menu bar.
private struct NotchScene<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            DesktopBackdrop()
            MenuBarStrip()
            content()
        }
        .frame(width: 760, height: 300, alignment: .top)
        .clipped()
    }
}

// MARK: - Stub engine

/// A no-op transcriber injected so constructing `AppState` for a render never
/// loads a Whisper model. `transcribe` is never called (no pipeline runs).
private final class PreviewTranscriber: TranscriptionEngine, @unchecked Sendable {
    var isReady: Bool { true }
    func prepare() async throws {}
    func transcribe(samples: [Float], language: LanguageMode, glossary: [String]) async throws
        -> TranscriptionResult
    {
        throw CancellationError()
    }
}
