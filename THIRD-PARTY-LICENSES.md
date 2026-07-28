# Third-Party Licenses

Shout itself is licensed under the GNU General Public License v3.0-or-later
(see [LICENSE](LICENSE)). It builds on the third-party components listed below.
Their licenses are permissive and GPL-compatible; the required copyright and
permission notices are reproduced here and, for redistributed binaries, are
also bundled inside `Shout.app` (see `scripts/bundle.sh`).

---

## whisper.cpp and ggml

On-device speech transcription is provided by
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) and its tensor library
[ggml](https://github.com/ggml-org/ggml). A prebuilt `whisper.xcframework`
(v1.9.1) is downloaded by SwiftPM from the `binaryTarget` declared in
`Package.swift` and **embedded into the distributed `Shout.app`**, so its
license travels with any binary you ship.

The corresponding source for that binary is whisper.cpp at tag `v1.9.1`
(<https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.1>); the framework
is the official release asset for that tag, pinned by SHA-256 in
`Package.swift`.

Both are distributed under the MIT License:

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The prebuilt framework additionally contains an MIT-licensed contribution that
carries its own in-file notice, and therefore travels with any binary copy:

- Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng — the YaRN RoPE scaling
  implementation in ggml.

That notice appears in the corresponding upstream source at whisper.cpp tag
`v1.9.1`, and is embedded in the framework binary Shout ships.

ggml's optional llamafile `sgemm` path (Copyright (c) 2024 Mozilla Foundation)
is *not* part of that binary: upstream's `build-xcframework.sh` leaves
`GGML_LLAMAFILE` off, so the official xcframework contains no `tinyBLAS` or
`llamafile_sgemm` code and no Mozilla notice. It is listed here only to record
that the omission was checked rather than assumed.

---

## Whisper speech model (OpenAI)

The speech model fetched by `scripts/fetch-model.sh`
(`ggml-large-v3-turbo.bin`) is OpenAI's Whisper `large-v3-turbo`, converted to
the ggml format and hosted at
[huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp).
The model is **not** redistributed with Shout — it is downloaded on the user's
machine during setup. OpenAI's Whisper is released under the MIT License:

```
MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Apple system frameworks

Shout links against Apple's system frameworks — including AVFoundation,
Accelerate, Metal, MetalKit, Core ML, AppKit, SwiftUI, Security,
ServiceManagement, CryptoKit, ApplicationServices, Core Graphics, and the
Foundation Models framework that powers the optional Apple Intelligence cleanup
pass — and against the platform C++ runtime (`libc++`). All of these ship as
part of macOS and are used under Apple's SDK license terms; none are
redistributed with Shout.

---

## Application icon

The Shout app icon (`Icon/Shout.icns` and `Icon/icon-1024.png`) is original
artwork made for this project — a megaphone glyph drawn from scratch as plain
vector geometry. It contains no third-party assets (in particular, no Apple SF
Symbols, whose license does not permit use in app icons) and is covered by
Shout's own GPL-3.0-or-later license.

Note: SF Symbols *are* used within the app's user interface at runtime (menu
bar, settings, profile glyphs) — the use Apple's license expressly allows. The
documentation screenshots and recordings under `docs/` are captures of that
interface and therefore contain rendered SF Symbols. No SF Symbol is
redistributed here as a standalone or repurposed asset, and none appear in the
app icon.
