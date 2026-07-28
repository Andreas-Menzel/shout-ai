#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Andreas Menzel
# Builds the release binary and assembles a signed Shout.app in build/.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Shout

APP=build/Shout.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp .build/release/Shout "$APP/Contents/MacOS/Shout"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Icon/Shout.icns "$APP/Contents/Resources/AppIcon.icns"

# Ship the licenses inside the app: the GPL must travel with the program, and
# the embedded whisper.framework (MIT) requires its notice in every copy.
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD-PARTY-LICENSES.md "$APP/Contents/Resources/THIRD-PARTY-LICENSES.txt"

# whisper.xcframework ships a dynamic framework — embed it and point the
# executable's rpath at Contents/Frameworks. SwiftPM fetches the xcframework
# itself (see the binaryTarget in Package.swift) and unpacks it under
# .build/artifacts/<package-dir>/, so glob the package directory.
SLICE=$(ls -d .build/artifacts/*/whisper/whisper.xcframework/macos-*/whisper.framework 2>/dev/null | head -1)
if [ -z "$SLICE" ]; then
    echo "error: whisper.framework not found under .build/artifacts — run 'swift build' first" >&2
    exit 1
fi
cp -R "$SLICE" "$APP/Contents/Frameworks/"

FW="$APP/Contents/Frameworks/whisper.framework"
# The upstream slice is a fat x86_64+arm64 binary; Shout is Apple-Silicon-only
# (Package.swift, and Apple Intelligence requires it), so the Intel half is dead
# weight. Thin the real binary inside Versions/A — this is a versioned framework
# whose top-level entries are symlinks into Versions/Current, and writing through
# one would replace the symlink and leave codesign with an unrecognisable bundle.
BIN="$FW/Versions/A/whisper"
if lipo -archs "$BIN" 2>/dev/null | grep -qw x86_64; then
    lipo -thin arm64 "$BIN" -output "$BIN.thin"
    mv "$BIN.thin" "$BIN"
fi

# Point the executable at the embedded framework. Only add the rpath if it isn't
# already there — and fail loudly if it can't be added, because the alternative is
# a dyld load failure at launch with a far worse message.
if ! otool -l "$APP/Contents/MacOS/Shout" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Shout"
fi

# Signing identity: explicit CODESIGN_IDENTITY wins, then any stable identity
# in the keychain (Apple Development / Developer ID / our self-signed one),
# then ad-hoc as a last resort.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development:|Developer ID Application:|Shout Dev Signing/ {print $2; exit}')
    IDENTITY="${IDENTITY:--}"
fi

ENTITLEMENTS="Resources/Shout.entitlements"

# Signing tiers. Hardened runtime + the Apple-events entitlement apply to any
# real identity, so a local build exercises the same runtime the release ships
# under. A secure --timestamp is added ONLY for a Developer ID identity (the one
# that gets notarized): it needs Apple's timestamp server, so requiring it for
# the self-signed dev cert would hang an offline `make run`.
case "$IDENTITY" in
    -)
        # Ad-hoc: fast local loop; hardened runtime needs a real identity.
        codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
        codesign --force --sign "$IDENTITY" "$APP"
        ;;
    "Developer ID Application:"*)
        # Release: notarization-ready — hardened runtime, entitlements, timestamp.
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
        codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
            --sign "$IDENTITY" "$APP"
        ;;
    *)
        # Dev identity (self-signed "Shout Dev Signing" or Apple Development):
        # hardened runtime + entitlements, no timestamp (works offline).
        codesign --force --options runtime \
            --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
        codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
            --sign "$IDENTITY" "$APP"
        ;;
esac

if [ "$IDENTITY" = "-" ]; then
    echo "⚠️  Ad-hoc signature: macOS ties permissions to each build, so ALL"
    echo "   privacy grants are now stale. Run 'make reset-permissions', then"
    echo "   re-grant in the app. Create a stable identity once with 'make cert'"
    echo "   (or Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates) to stop this."
else
    echo "Signed with: $IDENTITY"
fi
echo "Built $APP"
