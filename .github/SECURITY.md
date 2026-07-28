# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's [private vulnerability reporting](https://github.com/Andreas-Menzel/shout-ai/security/advisories/new)
— it goes straight to the maintainer and stays private until a fix is out. If that is
unavailable to you, email <mail@andreas-menzel.com> with `[shout-ai security]` in the subject.

Expect an acknowledgement within a week. Shout is a spare-time project, so please allow
reasonable time for a fix before disclosing publicly.

## Supported versions

Only the latest commit on `main` is supported. There are no maintained release branches, and
there is no auto-update mechanism — Shout is built from source, so *you* control when you pick
up a fix.

## Scope — what is worth reporting

Shout is a local-first dictation app, so its interesting surface is the local one:

- **Injected or leaked dictation content** — anything that gets transcript text to a place the
  user did not choose. The remote-endpoint path is opt-in and clearly marked; a way to reach it
  *without* the user selecting a remote model would be a serious bug.
- **Text insertion into the wrong target** — `TextInserter` checks the focused element and
  restores the clipboard; defeating either is in scope.
- **Keychain handling** — endpoint API keys live in the login Keychain under service
  `com.shoutai.Shout.endpoint-key`, device-bound. Any way to read them from another process, or
  to get one written somewhere else (preferences, logs, history), is in scope.
- **The model download** — `Package.swift` pins the whisper.cpp framework by SHA-256 and
  `WhisperModelSpec` pins the speech model. A way to get an unverified binary loaded is in scope.
- **History and logs** — dictation history is local and optional. Content leaking into
  `os_log` (which is world-readable on the machine) is in scope; the logging deliberately marks
  transcript text as private.

## Out of scope — intentional design decisions

These are documented choices, not oversights. Reporting them is fine, but they will be closed
as intended behaviour:

- **The app is not sandboxed.** It cannot be: it installs a global `CGEventTap` to watch the fn
  key, synthesizes ⌘V into other applications, and drives Spotify/Music over Apple Events. All
  three are incompatible with the App Sandbox. See `Resources/Shout.entitlements`.
- **`com.apple.security.cs.disable-library-validation`** is set so the hardened runtime will load
  the embedded `whisper.framework`, which is signed by its upstream publisher rather than by this
  project.
- **A global event tap sees key events while running.** That is the feature. The tap is
  `listenOnly` and Shout acts on fn and Esc only.
- **Synthesizing keystrokes requires Accessibility**, and watching the fn key requires Input
  Monitoring. Both are requested explicitly and are visible in System Settings.
- **A user-configured remote endpoint sends transcript text off the device.** This is the
  documented opt-in exception to local-only processing, surfaced in the model list, under the
  picker, and on the pill while it runs.
- **Self-signed / ad-hoc builds warn about stale privacy grants.** That is macOS tying TCC to the
  code signature, not a Shout bug.
