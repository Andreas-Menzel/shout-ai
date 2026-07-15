# Shout

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Local-first dictation for macOS — a Wispr-Flow-style tool where everything runs on your Mac.
Hold the **fn** key, speak German or English into any text field, release — and fluent,
cleaned-up text is inserted where your cursor is. **Everything runs on your Mac by default —
your audio never leaves the device, and your text stays on it too unless you deliberately
connect a remote cleanup model.**

> **Status:** developer build. Shout is currently built from source (there is no notarized
> download yet), so setup assumes Xcode and the command line.

## What it does

Shout lives in the menu bar. You hold a key, talk, and let go; it transcribes your speech
on-device with whisper.cpp, cleans it up with Apple Intelligence (removing "ähm"s, false
starts, and fixing grammar), and pastes the result into whatever app you're in. If Apple
Intelligence is off or unsure, it inserts the raw transcript instead — dictation never blocks.

## Requirements

- **macOS 26 or later**, on **Apple Silicon**
- **Xcode 26+** and its command-line tools (to build from source)
- **~2 GB free disk** for the speech model (~1.6 GB) and the whisper framework
- **Apple Intelligence** enabled — *optional*, only for the cleanup pass; transcription works without it

## Install

```sh
git clone <your-repo-url> shout-ai
cd shout-ai

make setup            # one-time: downloads whisper.xcframework (v1.9.1) + the 1.6 GB model
make cert             # recommended, one-time: a stable signing identity (see note below)
make run              # builds build/Shout.app and opens it
```

`make run` builds the app into `build/Shout.app` and launches it. Because there is no signed
release yet, you build it yourself.

**Why `make cert`?** macOS ties privacy permissions to an app's code signature. With an ad-hoc
signature, *every rebuild looks like a new app*, so your granted permissions go stale. `make cert`
creates one stable self-signed identity ("Shout Dev Signing") so permissions survive rebuilds.
macOS will ask for your login password to trust it, and for "Always Allow" on the first build.
An **Apple Development** certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +)
works too.

## First-run setup (the app walks you through this)

1. Grant **Microphone**, **Input Monitoring**, and **Accessibility** permissions.
2. System Settings › Keyboard › **"Press 🌐 key to" → "Do Nothing"**
   (otherwise macOS's own dictation/emoji picker fights over the fn key).
3. System Settings › **Apple Intelligence & Siri → enable Apple Intelligence**
   (needed for the cleanup pass; transcription works without it).

The Setup Assistant window opens on first launch and reports the live state of each item.
You can reopen it anytime from the menu bar (**Setup Assistant…**).

## Using Shout

Shout is a menu-bar app (a mic icon near the clock). Click it for status and actions:
Start/Finish dictation, **Pause Shout** (frees the fn key for other apps without quitting),
History…, Setup Assistant…, Settings…, and Quit.

**Dictating:**

- **Hold fn** and speak, release to insert (push-to-talk).
- **Double-tap fn** to lock hands-free recording; **tap fn** again to finish.
- **Esc** cancels — while recording *or* during transcription/cleanup.
- Dictations under 4 words (configurable) skip the cleanup pass and insert the raw transcript.
- A floating **pill** shows the current state (listening / transcribing / polishing / inserted).
  "Inserted raw" means the cleanup was skipped or fell back, so you may want to proofread.

**Settings** (from the menu bar):

- *General* — launch at login, show/style the pill (Classic capsule or Dynamic Island notch),
  live transcript preview, restore clipboard after inserting, and **Save dictation history**.
- *Dictation* — spoken language (auto / German / English), the fn hold threshold and
  double-tap window, and the cleanup toggle with its minimum-word count.
- *Glossary* — names and jargon Shout should spell exactly (e.g. product or people names).
- *Setup* — the permission checklist, available any time.

**History** — every dictation (raw + cleaned) is kept locally so you can review, search, copy,
or delete it. Turn it off with *General ▸ Save dictation history*, or clear it all from the
History window. History is never uploaded.

## Troubleshooting

- **The fn key only works inside Shout.** Input Monitoring isn't fully granted. Open Setup,
  grant it, and use **Restart Shout** — a running process can't pick up this permission live.
- **Permissions look enabled but nothing happens after a rebuild.** An ad-hoc signature made the
  entries stale. Run `make reset-permissions`, then re-grant them in Setup — or run `make cert`
  once so this stops happening.
- **"Downloading speech model…" or "not installed".** Open Setup and let the model finish
  downloading (or retry). A partial/failed download is detected and not used.
- **Text isn't inserted.** Grant **Accessibility** (the pill/notification says "grant
  Accessibility, press ⌘V"). Your text is kept on the clipboard so nothing is lost.
- **fn triggers macOS dictation or the emoji picker.** Set System Settings › Keyboard ›
  "Press 🌐 key to" → "Do Nothing".
- **Cleanup is skipped ("Inserted raw").** Apple Intelligence is off/unavailable, or the result
  failed a quality check — the raw transcript is inserted. Enable Apple Intelligence in System
  Settings to get the cleanup pass.

## Uninstall

Shout is self-contained, but it does touch a few system areas. To remove it completely:

```sh
# 1. Quit Shout (menu bar ▸ Quit) and turn OFF "Launch at login" first
#    (Settings ▸ General, or System Settings ▸ General ▸ Login Items).

# 2. Delete the app and build output
rm -rf build/Shout.app
make clean                     # removes .build and build/

# 3. Delete on-device data (the ~1.6 GB model, history, and any diagnostics)
rm -rf "$HOME/Library/Application Support/Shout"

# 4. Delete preferences
defaults delete com.shoutai.Shout 2>/dev/null || true

# 5. Reset the privacy permissions granted to Shout
make reset-permissions         # Accessibility, Input Monitoring, Post Events, Microphone

# 6. If you ran `make cert`, remove the self-signed identity
security delete-identity -c "Shout Dev Signing" 2>/dev/null || true

# 7. Optional: remove the fetched whisper framework and the cloned repo
rm -rf Vendor/whisper.xcframework
```

Finally, revert System Settings › Keyboard › **"Press 🌐 key to"** back to your preferred value
(it was set to "Do Nothing" during setup).

## Privacy & your data

By default everything runs on your Mac — audio is captured in memory only (never written to
disk), transcription and cleanup are on-device, and the only network request Shout makes on its
own is the one-time model download.

**The one exception is a remote cleanup model.** If you add an OpenAI-compatible endpoint on a
non-local host (Settings ▸ Dictation ▸ *Manage endpoints…*) and select it, that dictation's
**transcript text** is sent to that server to be cleaned up. Shout marks such models as leaving
your Mac — in the model list, in a warning under the picker, and with an indicator on the pill
while it runs — so it never happens silently. Your **audio** still never leaves the device, and
the on-device Apple Intelligence model remains the default. It writes three things locally:

- Speech model: `~/Library/Application Support/Shout/models/ggml-large-v3-turbo.bin`
- Dictation history: `~/Library/Application Support/Shout/history.json` (optional — see Settings)
- Preferences: the `com.shoutai.Shout` domain

## Contributing / developing

See [CONTRIBUTING.md](CONTRIBUTING.md) to get started. Architecture, build targets, tests, and
debugging tools live in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Version & license

Shout is at **v0.1.0** (developer preview).

It is free software under the **GNU General Public License v3.0-or-later** — see
[LICENSE](LICENSE). You may use, study, share, and modify it; derivative works must stay under
the GPL. Copyright © 2026 Andreas Menzel.

### Acknowledgements

Shout stands on excellent open-source work:

- **[whisper.cpp](https://github.com/ggml-org/whisper.cpp)** and **[ggml](https://github.com/ggml-org/ggml)** (MIT) — on-device speech transcription.
- **[OpenAI Whisper](https://github.com/openai/whisper)** (MIT) — the `large-v3-turbo` speech model, downloaded at setup.

Full third-party notices are in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
