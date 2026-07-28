#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Andreas Menzel
# Render documentation screenshots of the floating pill / notch island UI.
#
# No display is required: SwiftUI's ImageRenderer rasterises the real pill views
# off-screen (see Sources/Shout/ScreenshotRenderer.swift). The render is
# non-destructive — it never shows the live panel and never writes to the app's
# saved preferences.
#
# Usage: scripts/render-screenshots.sh [output-dir]   (default: docs/screenshots)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"

swift build --product Shout
SHOUT_RENDER_DIR="$OUT" ./.build/debug/Shout

echo "Screenshots written to $OUT"
