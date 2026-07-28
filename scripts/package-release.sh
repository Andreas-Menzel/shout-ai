#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Andreas Menzel
#
# Package build/Shout.app into a distributable archive for a GitHub release.
#
#   make dist                      # or: scripts/package-release.sh
#
# Produces dist/Shout-v<version>-arm64.zip plus a .sha256 next to it, and
# prints the command to attach both to the matching release.
#
# Why ditto and not zip(1): the embedded whisper.framework is a *versioned*
# bundle whose top-level entries are symlinks into Versions/Current. zip(1)
# would store them as copies, which changes the bundle layout and invalidates
# the signature — the app would then fail at launch, on the user's machine, with
# a message that points nowhere useful. ditto preserves symlinks and metadata,
# and this script proves it by extracting the archive again and re-verifying the
# signature before it will hand you an upload command.
#
# Deliberately NOT notarized: that needs a paid Developer ID. The archive is
# signed with the project's own identity, so users must clear the quarantine
# flag once after downloading (see the README). ALLOW_ADHOC=1 permits an ad-hoc
# signature, but see the warning it prints.

set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

APP="build/Shout.app"
PLIST="Resources/Info.plist"
DIST="dist"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
[[ -n "$VERSION" ]] || die "could not read CFBundleShortVersionString from $PLIST"
TAG="v$VERSION"
ARCHIVE="$DIST/Shout-$TAG-arm64.zip"

# ---- build ------------------------------------------------------------------

echo "Building and signing $APP for $TAG…"
rm -rf "$APP"
scripts/bundle.sh >/dev/null || die "bundle.sh failed"

# ---- verify what we are about to hand to strangers ---------------------------

built_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[[ "$built_version" == "$VERSION" ]] \
    || die "app reports $built_version but the manifest says $VERSION"

# Read the signature once into a variable rather than piping into `grep -q`:
# grep exits at the first match, codesign takes SIGPIPE, and under `pipefail`
# the pipeline then reports failure even though the match succeeded.
SIG="$(codesign -dvv "$APP" 2>&1)"

if [[ "$SIG" == *"Signature=adhoc"* ]]; then
    if [[ -z "${ALLOW_ADHOC:-}" ]]; then
        die "the app is ad-hoc signed. macOS ties privacy grants to the signature, so
       every release would silently reset users' Microphone, Accessibility and
       Input Monitoring grants. Run 'make cert' once for a stable identity, or
       set ALLOW_ADHOC=1 if you accept that."
    fi
    echo "  ⚠️  ad-hoc signature (ALLOW_ADHOC=1): users re-grant permissions on every update"
fi

codesign --verify --strict --deep "$APP" 2>/dev/null || die "signature does not verify"
[[ "$SIG" == *"flags=0x10000(runtime)"* ]] \
    || die "hardened runtime is not enabled — expected from bundle.sh's signing tiers"

for arch_target in "$APP/Contents/MacOS/Shout" "$APP/Contents/Frameworks/whisper.framework/Versions/A/whisper"; do
    archs="$(lipo -archs "$arch_target")"
    [[ "$archs" == "arm64" ]] || die "$arch_target is '$archs', expected arm64 only"
done

# The GPL must travel with the binary, and whisper.cpp's MIT notice with any
# copy of the framework. bundle.sh puts both inside the app — confirm, because
# shipping without them is a licence violation, not a cosmetic slip.
for licence in LICENSE.txt THIRD-PARTY-LICENSES.txt; do
    [[ -s "$APP/Contents/Resources/$licence" ]] || die "$licence missing from the app bundle"
done

symlinks_before="$(find "$APP" -type l | wc -l | tr -d ' ')"
echo "  verified: $VERSION · arm64 · hardened runtime · licences embedded · $symlinks_before symlinks"

# ---- package ----------------------------------------------------------------

mkdir -p "$DIST"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

# ---- prove the archive is not subtly broken ---------------------------------

ROUNDTRIP="$(mktemp -d)"
trap 'rm -rf "$ROUNDTRIP"' EXIT
ditto -x -k "$ARCHIVE" "$ROUNDTRIP" || die "could not extract $ARCHIVE"

EXTRACTED="$ROUNDTRIP/Shout.app"
[[ -d "$EXTRACTED" ]] || die "extracted archive has no Shout.app at its root"

symlinks_after="$(find "$EXTRACTED" -type l | wc -l | tr -d ' ')"
[[ "$symlinks_after" == "$symlinks_before" ]] \
    || die "packaging lost symlinks ($symlinks_before before, $symlinks_after after) — the framework bundle would be broken"

codesign --verify --strict --deep "$EXTRACTED" 2>/dev/null \
    || die "the signature does not verify after a round trip through the archive"

# Written in shasum(1)'s own format, with the bare filename, so a user who
# downloads both files into one directory can just run `shasum -a 256 -c`.
SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256"
SIZE="$(du -h "$ARCHIVE" | awk '{print $1}')"

echo "  round trip: signature valid, $symlinks_after/$symlinks_before symlinks intact"
echo
echo "$ARCHIVE  ($SIZE)"
echo "  sha256: $SHA"
echo
echo "Attach both to the release:"
echo
echo "  gh release upload $TAG \"$ARCHIVE\" \"$ARCHIVE.sha256\" --clobber"
echo
echo "Users must clear the quarantine flag once after downloading, because this"
echo "build is signed but not notarized — the README's Download section covers it."
