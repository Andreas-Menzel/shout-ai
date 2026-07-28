# Contributing to Shout

Thanks for your interest in Shout! Bug reports, fixes, and features are all
welcome.

## License of contributions

Shout is licensed under the **GNU General Public License v3.0-or-later**. By
submitting a contribution you agree that it will be licensed under those same
terms.

## Getting set up

You'll need **macOS 26+ on Apple Silicon** and **Xcode 26+**. Then:

```sh
swift test      # works straight from a fresh clone — no setup step needed
```

SwiftPM fetches and checksum-verifies the whisper.cpp framework itself, so building and testing
need nothing else. To actually *run* Shout and dictate:

```sh
make setup      # one-time: the 1.6 GB speech model
make cert       # optional: a stable signing identity so permissions survive rebuilds
make run        # build and launch build/Shout.app
```

Architecture, build targets, the test suite, and debugging tools are documented
in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Before you open a pull request

- **Run the tests:** `swift test` (the suite covers the engine layer's logic).
- **Keep it building** in debug and release: `swift build` / `make build`.
- Match the surrounding style — small, focused types behind protocols, with
  doc comments that explain *why*.
- Add or update tests for any behavior change.
- If you touch the built-in rewrite prompts, follow the prompt-eval workflow in
  the development docs — prompt changes are validated, not guessed.

## Reporting bugs

Open an issue with your macOS version, whether Apple Intelligence is enabled,
and clear steps to reproduce. Because Shout is local-first, please **never**
paste private dictation content into a public issue.

## Third-party code

Shout builds on whisper.cpp / ggml and OpenAI's Whisper model — see
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
