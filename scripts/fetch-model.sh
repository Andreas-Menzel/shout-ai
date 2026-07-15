#!/bin/bash
# Pre-downloads the Whisper model to Application Support (the app can also
# download it itself from the Setup window).
set -euo pipefail

DEST="$HOME/Library/Application Support/Shout/models/ggml-large-v3-turbo.bin"
MIN_SIZE=1500000000

if [ -f "$DEST" ] && [ "$(stat -f%z "$DEST")" -ge "$MIN_SIZE" ]; then
    echo "model already present"
    exit 0
fi

mkdir -p "$(dirname "$DEST")"
# -f fails loudly on an HTTP error instead of saving an error page as the model;
# force HTTPS/TLS so the download can't be silently downgraded.
curl -fL -C - --proto '=https' --tlsv1.2 --create-dirs -o "$DEST" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

# Integrity pin: verify the download's SHA-256 before trusting it. Defaults to
# the known-good hash of the official file (kept in sync with
# WhisperModelSpec.largeV3Turbo.sha256); override with SHOUT_MODEL_SHA256 for a
# different model. A mismatch deletes the file and fails.
EXPECTED_SHA256="${SHOUT_MODEL_SHA256:-1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69}"
echo "$EXPECTED_SHA256  $DEST" | shasum -a 256 -c - \
    || { echo "checksum mismatch — deleting $DEST"; rm -f "$DEST"; exit 1; }
echo "model installed at $DEST"
