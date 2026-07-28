#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Andreas Menzel
# Render short looping clips of the classic pill UI, off-screen and with a
# transparent background.
#
# No display is required: the real SwiftUI pill views are rasterised
# frame-by-frame on a clear canvas (SwiftUI's animation clock doesn't run under
# ImageRenderer, so motion is authored — see ScreenshotRenderer.runFrames) and
# ffmpeg stitches them into alpha-capable formats. Non-destructive; touches no
# prefs.
#
# Output formats carry an alpha channel (H.264/MP4 and GIF can't do soft-edged
# transparency): APNG for web/README <img>, WebM/VP9 for HTML <video>, ProRes
# 4444 .mov for macOS editing (Keynote / Final Cut).
#
# Requires ffmpeg (brew install ffmpeg).
# Usage: scripts/render-recording.sh [output-dir]   (default: docs/recordings)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-docs/recordings}"
FPS=24

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }

FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT

swift build --product Shout
SHOUT_RENDER_FRAMES="$FRAMES" ./.build/debug/Shout
mkdir -p "$OUT"

EVEN="scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos" # keep @2x, force even dims
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

# Lossless-alpha intermediates (QuickTime RLE keeps the alpha channel).
seq_to_qtrle()   { ffmpeg -y -loglevel error -framerate "$FPS" -i "$1/frame_%04d.png" -c:v qtrle "$2"; }
still_to_qtrle() { ffmpeg -y -loglevel error -loop 1 -t "$2" -i "$1" -r "$FPS" -c:v qtrle "$3"; }

# Encode one alpha source (a .mov) to the three transparent delivery formats.
alpha_outputs() { # <input.mov> <out-basename>
  local in="$1" base="$OUT/$2"
  ffmpeg -y -loglevel error -i "$in" -vf "$EVEN" -plays 0 -f apng "$base.apng"
  ffmpeg -y -loglevel error -i "$in" -vf "$EVEN,format=yuva420p" \
    -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 30 -an "$base.webm"
  ffmpeg -y -loglevel error -i "$in" -vf "$EVEN,format=yuva444p10le" \
    -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le -movflags +faststart "$base.mov"
}

# 1) Recording only — the seamless "listening" loop.
seq_to_qtrle "$FRAMES/clip-classic-recording" "$FRAMES/rec.mov"
alpha_outputs "$FRAMES/rec.mov" "pill-classic-recording"

# 2) Full workflow — recording → transcribing → polishing → inserted.
# ffmpeg's xfade drops alpha, so transitions are alpha-fades composited with
# time-shifted overlay onto a transparent base (a real cross-dissolve that
# keeps transparency).
seq_to_qtrle   "$FRAMES/clip-classic-recording"      "$FRAMES/wf-rec.mov"
seq_to_qtrle   "$FRAMES/clip-classic-transcribing"   "$FRAMES/wf-tr.mov"
still_to_qtrle "$FRAMES/still-classic-polishing.png" 1.3 "$FRAMES/wf-pol.mov"
still_to_qtrle "$FRAMES/still-classic-inserted.png"  1.6 "$FRAMES/wf-ins.mov"

XF=0.35
W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$FRAMES/wf-rec.mov")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$FRAMES/wf-rec.mov")
dR=$(dur "$FRAMES/wf-rec.mov"); dT=$(dur "$FRAMES/wf-tr.mov")
dP=$(dur "$FRAMES/wf-pol.mov"); dI=$(dur "$FRAMES/wf-ins.mov")
o1=$(echo "$dR - $XF" | bc -l)
o2=$(echo "$dR + $dT - 2 * $XF" | bc -l)
o3=$(echo "$dR + $dT + $dP - 3 * $XF" | bc -l)
TOTAL=$(echo "$dR + $dT + $dP + $dI - 3 * $XF" | bc -l)
foT=$(echo "$dT - $XF" | bc -l)
foP=$(echo "$dP - $XF" | bc -l)

FILTER="color=c=black@0.0:s=${W}x${H}:r=${FPS}:d=${TOTAL},format=rgba[bg];\
[0:v]format=rgba,fade=t=out:st=${o1}:d=${XF}:alpha=1,setpts=PTS-STARTPTS[a0];\
[1:v]format=rgba,fade=t=in:st=0:d=${XF}:alpha=1,fade=t=out:st=${foT}:d=${XF}:alpha=1,setpts=PTS-STARTPTS+${o1}/TB[a1];\
[2:v]format=rgba,fade=t=in:st=0:d=${XF}:alpha=1,fade=t=out:st=${foP}:d=${XF}:alpha=1,setpts=PTS-STARTPTS+${o2}/TB[a2];\
[3:v]format=rgba,fade=t=in:st=0:d=${XF}:alpha=1,setpts=PTS-STARTPTS+${o3}/TB[a3];\
[bg][a0]overlay=eof_action=pass:repeatlast=0[b0];\
[b0][a1]overlay=eof_action=pass:repeatlast=0[b1];\
[b1][a2]overlay=eof_action=pass:repeatlast=0[b2];\
[b2][a3]overlay=eof_action=pass:repeatlast=0[v]"
ffmpeg -y -loglevel error \
  -i "$FRAMES/wf-rec.mov" -i "$FRAMES/wf-tr.mov" -i "$FRAMES/wf-pol.mov" -i "$FRAMES/wf-ins.mov" \
  -filter_complex "$FILTER" -map "[v]" -c:v qtrle "$FRAMES/wf-alpha.mov"
alpha_outputs "$FRAMES/wf-alpha.mov" "pill-classic-workflow"

echo "Recordings written to $OUT:"
ls -lh "$OUT"/pill-*
