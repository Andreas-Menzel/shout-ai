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
