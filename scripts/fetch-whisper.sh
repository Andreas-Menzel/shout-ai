#!/bin/bash
# Downloads the prebuilt whisper.cpp xcframework (one time).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v1.9.1
DEST=Vendor/whisper.xcframework

if [ -d "$DEST" ]; then
    echo "whisper.xcframework already present"
    exit 0
fi

mkdir -p Vendor
cd Vendor
# -f fails loudly on an HTTP error; force HTTPS/TLS (this framework is executed).
curl -fL --proto '=https' --tlsv1.2 -o whisper-xcframework.zip \
    "https://github.com/ggml-org/whisper.cpp/releases/download/${VERSION}/whisper-${VERSION}-xcframework.zip"

# Integrity pin on the executable framework before we unzip and trust it. TLS
# authenticates the transport; this also catches a moved release tag or a
# re-published asset. Pinned to the v1.9.1 asset; override with
# SHOUT_WHISPER_SHA256 if you bump VERSION (get it with
# `shasum -a 256 whisper-xcframework.zip` after a known-good download).
EXPECTED_SHA256="${SHOUT_WHISPER_SHA256:-8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c}"
echo "$EXPECTED_SHA256  whisper-xcframework.zip" | shasum -a 256 -c - \
    || { echo "checksum mismatch — refusing to install"; rm -f whisper-xcframework.zip; exit 1; }
unzip -q -o whisper-xcframework.zip
# The zip nests the framework under build-apple/.
[ -d build-apple/whisper.xcframework ] && mv build-apple/whisper.xcframework . && rmdir build-apple
rm whisper-xcframework.zip
echo "whisper.xcframework installed"
