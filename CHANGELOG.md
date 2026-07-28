# Changelog

All notable changes to Shout are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Shout aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The authoritative version
number is `CFBundleShortVersionString` in `Resources/Info.plist`.

## [Unreleased]

Release-readiness work ahead of going public. Folded into 1.0.0 if it is tagged from here.

### Added

- Community health files: `SECURITY.md` (including the intentional non-sandbox posture),
  `CODE_OF_CONDUCT.md`, issue and pull-request templates, and this changelog.
- GitHub Actions CI: builds debug and release, runs the test suite, assembles an ad-hoc-signed
  `Shout.app`, and smoke-tests the off-screen documentation renderer.

### Changed

- **The whisper.cpp framework is now fetched by SwiftPM**, as a `binaryTarget` with a pinned
  URL and SHA-256, instead of by a setup script into `Vendor/`. `swift build` and `swift test`
  now work straight from a fresh clone; `make setup` only downloads the speech model, which is
  needed to dictate but not to build or test. Removes `scripts/fetch-whisper.sh`.
- The speech model's size gate is now its exact byte count rather than a floor, and
  `scripts/fetch-model.sh` verifies the SHA-256 on every run rather than only after a fresh
  download — so a download truncated near the end is rejected instead of being reported as
  present.
- Documentation corrections ahead of the first public release: the Keychain is now listed among
  the things Shout stores locally and in the uninstall steps; the Automation prompt raised by
  media auto-pause is documented; the third-party notices no longer claim that no SF Symbols are
  redistributed as image files, and now state the corresponding source for the embedded
  framework.
- Built-in prompt and evaluation fixtures use neutral example content.
- The documentation screenshot renderer (and the `AppState` hooks it drives) is now `#if DEBUG`,
  so ~370 lines of docs tooling and a check on the hot path of every state change no longer ship
  in release builds. Both consumers already used the debug binary, so nothing changed for them.
- Interim transcription passes now copy only the bounded head/tail windows they decode instead of
  the whole take. Holding a whole-buffer snapshot left the recorder's array multiply-referenced,
  so the next append on the audio render thread copied everything — up to 19 MB at the maximum
  dictation length, every 250–600 ms. That was a plausible cause of audio glitches on long
  hands-free takes.
- Loopback detection now covers all of `127.0.0.0/8` and `.localhost`, so a local endpoint on
  `127.0.0.2` is no longer labelled as leaving your Mac.
- The embedded `whisper.framework` is thinned to arm64 when bundling: 5.5 MB → 2.7 MB, for a
  6.4 MB app. `bundle.sh` also no longer swallows an `install_name_tool` failure, which would
  have surfaced later as a dyld load error.
- Corrected comments that described `prewarm` as caching the instruction prefill across
  dictations. It does not — prefill is per session, and each rewrite deliberately gets a fresh
  session so one dictation cannot leak into the next one's context.

### Removed

- Dead code: `ProfileStore.addProfile` and `ProfileStore.update` (superseded by `duplicate` and
  `save`), `ModelRegistry.defaultEntry`, and the unused `Theme.Space.xs`/`.xl` steps.

## [1.0.0] — not yet tagged

First public release. Built from source; no notarized download yet.

- Push-to-talk dictation: hold **fn** to record, release to insert; double-tap to latch
  hands-free; **Esc** cancels at any stage.
- On-device transcription with whisper.cpp (`large-v3-turbo`, Metal), German and English with
  auto-detection.
- On-device cleanup with Apple Intelligence, with a deterministic `TextNormalizer` pass and a
  guardrail that inserts the raw transcript rather than a bad rewrite.
- Optional OpenAI-compatible endpoints for the cleanup stage, including local servers (Ollama,
  LM Studio). Remote hosts are marked everywhere they appear.
- Profiles: Clean-up, Professional writing, Prompt engineer, Summarize, Translate → English,
  plus user-defined profiles with their own prompt, model, glyph, and tint.
- Optional spoken profile switching ("use profile summarize, …") with audible confirmation cues.
- Floating pill UI in two styles (classic capsule, Dynamic Island notch), with live transcript
  preview.
- Optional local dictation history, glossary for names and jargon, and media auto-pause for
  Spotify and Apple Music.

[Unreleased]: https://github.com/Andreas-Menzel/shout-ai/commits/main
