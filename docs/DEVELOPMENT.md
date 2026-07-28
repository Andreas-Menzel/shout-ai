# Developing Shout

Developer-facing notes: architecture, build targets, testing, and debugging. For installing and
using the app, see the [README](../README.md).

## How it works

| Stage | Engine | Where |
|---|---|---|
| Hotkey | `CGEventTap` watching the fn key (listen-only) | in-process |
| Audio | `AVAudioEngine`, 16 kHz mono, in memory only | on-device |
| Speech-to-text | whisper.cpp `large-v3-turbo` (Metal), German/English auto-detect | on-device |
| Cleanup | Apple Foundation Models (Apple Intelligence) — the default | on-device |
| Cleanup (opt-in) | any OpenAI-compatible endpoint via `EndpointRewriter` | local server, or remote if the user chooses one |
| Insertion | concealed clipboard + synthetic ⌘V, previous clipboard restored | in-process |

The two AI stages sit behind protocols in `ShoutCore/Engines.swift`:

- `TranscriptionEngine` — `WhisperTranscriber` today.
- `RewriteEngine` — `AppleFoundationRewriter` today.

`AppState` depends only on the protocols (via injected `any TranscriptionEngine` / `any
RewriteEngine`), and `EngineFactory` is the single place that names a concrete backend. The set of
selectable rewrite models is data, not code: `ModelRegistry` holds the built-in on-device
`ModelEntry` plus any user-added OpenAI-compatible endpoints (managed in *Settings ▸ Dictation ▸
Manage endpoints…*), and a `Profile` points at one by `modelID`. Adding a new *backend kind* is a
new `RewriteEngine` conformer plus one case in `EngineFactory`.

`DictationPipeline` (transcribe → optionally rewrite → deterministic `TextNormalizer`) is kept
free of UI/insertion/history so its fallback logic is unit-testable. `FnGestureRecognizer` is a
pure state machine for the fn gestures, shared by `AppState` and the `fnwatch` diagnostic.

## Requirements

macOS 26+, Apple Silicon, Xcode 26+. See the README for the full list.

## Build

```sh
make setup            # one-time: fetch the 1.6 GB speech model (only needed to dictate)
make build            # swift build -c release
make cli              # build just the shout-cli test harness
make bundle           # assemble a signed build/Shout.app
make run              # bundle + open
make cert             # one-time: stable self-signed signing identity (permissions survive rebuilds)
make reset-permissions# clear stale TCC entries after a signature change
make clean            # rm -rf .build build
```

`scripts/bundle.sh` picks the signing identity in this order: an explicit `CODESIGN_IDENTITY`, then
any stable keychain identity (Apple Development / Developer ID / the `make cert` "Shout Dev
Signing"), then ad-hoc as a last resort. Ad-hoc signatures make macOS treat every rebuild as a new
app, so privacy grants go stale — run `make cert` once to avoid that.

`swift build` and `swift test` need no setup step: the whisper.cpp framework (v1.9.1) is a
`binaryTarget` with a `url` + `checksum` in `Package.swift`, so SwiftPM downloads it into
`.build/artifacts/` and refuses it on a checksum mismatch — bump the URL and checksum together.
`make setup` only fetches the speech model, which nothing but real dictation needs.

The model is SHA-256-pinned in two places that must stay in sync: `WhisperModelSpec` (enforced on
the app's own download, before the file is ever handed to native ggml) and the default in
`scripts/fetch-model.sh` (verified on *every* run, so a previously interrupted file is caught
rather than trusted). Both also check the exact expected byte size, so a download truncated near
the end is rejected instead of passing as complete. Override with `SHOUT_MODEL_SHA256` when
bumping the model.

## Testing

```sh
swift test                                          # unit tests for the ShoutCore pure logic
```

Covers the pure engine-layer logic: `TextNormalizer` (glossary + fillers), the profile quality
guards, `WhisperTranscriber.tidy`, `FnGestureRecognizer`, `DictationPipeline` (with fake engines),
`withTimeout`, `VoiceCommand` + `VoiceSwitchDecision` (spoken profile switching), `EndpointRewriter`
(SSE assembly, `<think>` stripping, the insecure-HTTP gate, loopback classification),
`WhisperModelSpec.validateFile` + `ModelManager` (the exact-size and SHA-256 gates that stand
between a downloaded blob and native ggml), `AudioRecorder`'s interim window arithmetic, `Profile`
(upgrade + glyph fallbacks), `MediaPauseCoordinator`, `ChimeSynth`, and `VoiceActivityTracker`.

The suite is hermetic — no network (`EndpointRewriterTests` stubs `URLSession` with a custom
`URLProtocol`), no speech model, no Apple Intelligence — so it runs anywhere, including CI.

Exercise the engines from the command line without the UI:

```sh
make cli
CLI=.build/release/shout-cli

$CLI status                                   # model + Apple Intelligence availability
$CLI transcribe voice.aiff [auto|de|en]       # whisper only
$CLI rewrite <text> [lang] [profile] [terms]  # cleanup via the on-device model
$CLI rewrite-endpoint <baseURL> <model> <text> [lang]   # via an OpenAI-compatible endpoint
$CLI pipeline voice.aiff [lang]               # both stages, with timings
$CLI voice-switch <transcript> [trigger]      # spoken profile-switch parsing
$CLI diagnose-profile <taskPrompt> <text> [lang]        # assembled prompt + raw model output
$CLI fnwatch [seconds]                        # fn-key event trace (see Debugging)
```

`profile` is one of `cleanup`, `professional`, `prompt`, `summarize`, `translate`.
`diagnose-profile` takes a **task prompt directly**, not a profile name — paste one from
`Profile+BuiltIns.swift` (or your own draft) to see exactly what gets sent and what comes back.
That is the fastest way to understand why a prompt misbehaves.

Generate test audio: `say -v Anna -o voice.aiff "Ähm, also eigentlich…"`
(`AudioFileLoader` uses `AVAudioFile`, so any format it reads works.)

## Prompt evaluation

The built-in rewrite prompts are validated, not guessed. After any change to
`Profile+BuiltIns.swift` or `RewriteSupport.swift`:

```sh
make cli && scripts/prompt-eval.sh
```

This runs every built-in profile against a fixed panel of German and English dictation cases on
the real on-device model — including the filler, self-correction, glossary, and prompt-injection
cases that regress most easily. There is **no automatic scoring**: decoding is greedy, so runs
are reproducible and the workflow is to keep the previous run's output and diff against it. Judge
each case by its profile's contract, documented in the script's header comment.

Two rules when you change a built-in's task prompt:

1. **Append the outgoing text to `Profile.previousBuiltInTaskPrompts`.** Seeded profiles live in
   `UserDefaults`, so a shipped prompt improvement never reaches an existing install by itself.
   On launch, `upgradeBuiltIns` replaces a stored prompt that still matches a previous shipped
   version *verbatim* — that is how it distinguishes "never customized" from "user edited it".
   Skip this and users keep the old prompt forever. `ProfileTests` enforces that no history entry
   equals a current prompt.
2. **Re-run the panel.** The prompts carry few-shot examples; a small wording change can shift
   behaviour on the self-correction cases in particular.

Known model limit (Apple Foundation Models, ≈3B): clause-level self-corrections such as "Dann
kannst du, nee warte, ich …" may keep the abandoned fragment. That errs toward preserving what
was said, so it is the safe direction — see case `C3`.

## Documentation media

The screenshots and recordings under `docs/` are generated, not captured — `ScreenshotRenderer`
rasterises the real pill and notch views through SwiftUI's `ImageRenderer`, so **no display,
window server, or running app is needed** and nothing from the developer's desktop can leak in.

```sh
make screenshots     # docs/screenshots/*.png
make recordings      # docs/recordings/*.apng + *.webm  (needs: brew install ffmpeg)
```

Both are driven by env vars read at process start (`ShoutApp.swift`), each naming an output
directory and switching the binary into render mode instead of launching the app:
`SHOUT_RENDER_DIR` writes the still screenshots, `SHOUT_RENDER_FRAMES` writes an animation frame
sequence for ffmpeg to stitch. The heavy ProRes masters that
`render-recording.sh` produces are gitignored — only the light web assets are committed. Note the
PNG output is not byte-reproducible, so re-rendering always shows a diff even when nothing
visibly changed.

## Debugging

- **Logs:** `log stream --predicate 'subsystem == "de.menzelini.shout"'` (categories: `app`,
  `audio`, `whisper`, `rewrite`, `model`).
- **fn key:** `.build/release/shout-cli fnwatch [seconds]` creates the same listen-only tap the app
  uses and logs every fn/key event plus the gesture intents the shared `FnGestureRecognizer` emits,
  to `~/Library/Application Support/Shout/fnwatch.log`. Run it from a Terminal that has Input
  Monitoring — the grant sticks to Terminal, so it doesn't disturb the app's own permissions.

## Project layout

```
Sources/ShoutCore/       engine layer (no UI)
  AudioRecorder.swift        mic capture → 16 kHz mono Float32 (in memory)
  WhisperTranscriber.swift   whisper.cpp TranscriptionEngine, glossary hints
  AppleFoundationRewriter.swift  Apple Intelligence RewriteEngine + quality guard
  DictationPipeline.swift    transcribe → rewrite → normalize (testable)
  Engines.swift              engine protocols, factory, Tuning constants
  FnGesture.swift            pure fn-gesture recognizer (shared with the CLI)
  ModelManager.swift         model download/validation/state
  TextNormalizer.swift       deterministic glossary + filler cleanup
Sources/Shout/           the menu-bar app
  AppState.swift             coordinator: gestures → pipeline → insert → history
  FnKeyMonitor.swift         listen-only CGEventTap for fn/esc
  TextInserter.swift         concealed-clipboard paste with target check + restore
  PermissionsManager.swift   TCC status, fn-key system setting, deep links
  SettingsStore / HistoryStore   preferences and local history
  UI/                        Theme, menu bar, pill, notch pill, settings, setup, history
Sources/shout-cli/       headless test harness + fnwatch diagnostic
Tests/ShoutCoreTests/    unit tests for the engine layer's pure logic
```

(Selected files — the tree above names the load-bearing types, not every source file.)
The whisper.xcframework is not in the repo: SwiftPM fetches it into `.build/artifacts/`.
