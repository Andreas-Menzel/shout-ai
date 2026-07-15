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
(v1.9.1) is downloaded by `scripts/fetch-whisper.sh` and **embedded into the
distributed `Shout.app`**, so its license travels with any binary you ship.

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

Shout links against Apple's system frameworks — AVFoundation, Accelerate,
Metal, MetalKit, Core ML, AppKit, SwiftUI, and the Foundation Models framework
that powers the optional Apple Intelligence cleanup pass. These ship as part of
macOS and are used under Apple's SDK license terms; they are not redistributed
with Shout.

---

## Application icon

The Shout app icon (`Icon/Shout.icns` and `Icon/icon-1024.png`) is original
artwork made for this project — a megaphone glyph drawn from scratch as plain
vector geometry. It contains no third-party assets (in particular, no Apple SF
Symbols, whose license does not permit use in app icons) and is covered by
Shout's own GPL-3.0-or-later license.

Note: SF Symbols *are* used within the app's user interface at runtime (menu
bar, settings, profile glyphs) — the use Apple's license expressly allows — but
none are redistributed as image files in this repository.
