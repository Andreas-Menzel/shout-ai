# Developing Shout

Developer-facing notes: architecture, build targets, testing, and debugging. For installing and
using the app, see the [README](../README.md).

## How it works

| Stage | Engine | Where |
|---|---|---|
| Hotkey | `CGEventTap` watching the fn key (listen-only) | in-process |
| Audio | `AVAudioEngine`, 16 kHz mono, in memory only | on-device |
| Speech-to-text | whisper.cpp `large-v3-turbo` (Metal), German/English auto-detect | on-device |
| Cleanup | Apple Foundation Models (Apple Intelligence) | on-device |
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
make setup            # one-time: fetch whisper.xcframework (v1.9.1) + the 1.6 GB model
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

The model and the whisper framework are both SHA-256-pinned: `make setup` verifies each download
against a known-good hash (`WhisperModelSpec.sha256` / the default in `fetch-model.sh`, and the pin
in `fetch-whisper.sh`) and fails closed on a mismatch. Override with `SHOUT_MODEL_SHA256` /
`SHOUT_WHISPER_SHA256` when bumping a version.

## Testing

```sh
swift test                                          # unit tests for the ShoutCore pure logic
```

Covers the pure engine-layer logic: `TextNormalizer` (glossary + fillers), the profile quality
guards, `WhisperTranscriber.tidy`, `FnGestureRecognizer`, `DictationPipeline` (with fake engines),
`withTimeout`, `VoiceCommand` + `VoiceSwitchDecision` (spoken profile switching), `EndpointRewriter`
(SSE assembly, `<think>` stripping, the insecure-HTTP gate), `Profile` (upgrade + glyph fallbacks),
`MediaPauseCoordinator`, `ChimeSynth`, and `VoiceActivityTracker`.

Exercise the engines from the command line without the UI:

```sh
make cli
.build/release/shout-cli status                     # model + Apple Intelligence availability
.build/release/shout-cli transcribe voice.wav       # whisper only (auto language)
.build/release/shout-cli rewrite "ähm also ich..."  # cleanup only
.build/release/shout-cli pipeline voice.wav         # both stages, with timings
```

Generate test audio: `say -v Anna -o test.aiff "Ähm, also eigentlich…"`

## Debugging

- **Logs:** `log stream --predicate 'subsystem == "com.shoutai.Shout"'` (categories: `app`,
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
Vendor/                  whisper.xcframework (fetched, not committed)
```
