#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Andreas Menzel
#
# Cut a release: set the version everywhere, close the changelog section, run
# the tests, then commit and tag. Pushing stays manual — the script prints the
# commands and stops, so nothing reaches the public repo by accident.
#
#   make bump VERSION=1.0.1              # or: scripts/bump-version.sh 1.0.1
#   DRY_RUN=1 make bump VERSION=1.0.1    # show the diff, then undo it
#
# CFBundleShortVersionString in Resources/Info.plist is the authoritative
# version. This keeps README.md and CHANGELOG.md in step with it, and stamps
# CFBundleVersion with the commit count so every build has a distinct,
# increasing build number (macOS compares it when deciding what is newer).
#
# Escape hatches, all off by default: ALLOW_BRANCH=1 to release off main,
# SKIP_TESTS=1 to skip the suite, DRY_RUN=1 to preview.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_URL="https://github.com/Andreas-Menzel/shout-ai"
PLIST="Resources/Info.plist"
README="README.md"
CHANGELOG="CHANGELOG.md"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: $(basename "$0") <version>   e.g. $(basename "$0") 1.0.1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "'$VERSION' is not a semantic version like 1.0.1 or 1.1.0-rc.1"

TAG="v$VERSION"
DATE="$(date +%F)"

# ---- preflight -------------------------------------------------------------

git diff --quiet && git diff --cached --quiet \
    || die "working tree is dirty — commit or stash first, so the release commit holds only the version bump"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && -z "${ALLOW_BRANCH:-}" ]]; then
    die "on branch '$BRANCH', not main — re-run with ALLOW_BRANCH=1 if that is deliberate"
fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    && die "tag $TAG already exists locally — pick another version, or delete it with 'git tag -d $TAG'"

if remote_tag="$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)" && [[ -n "$remote_tag" ]]; then
    die "tag $TAG already exists on origin — a published tag must not be moved; pick another version"
fi

# ---- changelog: decide what this release closes -----------------------------

unreleased_line="$(grep -n '^## \[Unreleased\]' "$CHANGELOG" | head -1 | cut -d: -f1 || true)"
version_line="$(grep -n "^## \[$VERSION\]" "$CHANGELOG" | head -1 | cut -d: -f1 || true)"

unreleased_has_content=0
if [[ -n "$unreleased_line" ]]; then
    # Any non-blank line between this heading and the next one.
    if awk -v start="$unreleased_line" 'NR > start { if ($0 ~ /^## /) exit; if ($0 ~ /[^[:space:]]/) { found = 1; exit } }
         END { exit !found }' "$CHANGELOG"; then
        unreleased_has_content=1
    fi
fi

if [[ -n "$version_line" && "$unreleased_has_content" == 1 ]]; then
    die "$CHANGELOG has both an [Unreleased] section with items and a [$VERSION] section.
       Deciding which prose belongs where is an editorial call, not a mechanical one:
       fold the [Unreleased] items into [$VERSION] by hand, then re-run."
fi

if [[ -n "$version_line" ]]; then
    MODE="date-existing"     # e.g. a '## [1.0.0] — not yet tagged' section
elif [[ "$unreleased_has_content" == 1 ]]; then
    MODE="promote-unreleased"
else
    die "nothing to release: $CHANGELOG has no [$VERSION] section and no items under [Unreleased].
       Write the entries first — a tag with an empty changelog tells users nothing."
fi

echo "Releasing $TAG ($MODE), dated $DATE"

# ---- edits -----------------------------------------------------------------

set_plist_string() { # <key> <value>  — rewrites the <string> on the line after <key>
    local key="$1" value="$2"
    awk -v key="$key" -v value="$value" '
        index($0, "<key>" key "</key>") {
            print
            if ((getline nextline) > 0) {
                sub(/<string>[^<]*<\/string>/, "<string>" value "</string>", nextline)
                print nextline
            }
            next
        }
        { print }
    ' "$PLIST" > "$PLIST.tmp" && mv "$PLIST.tmp" "$PLIST"
}

BUILD="$(git rev-list --count HEAD)"
set_plist_string CFBundleShortVersionString "$VERSION"
set_plist_string CFBundleVersion "$BUILD"
grep -q "<string>$VERSION</string>" "$PLIST" || die "failed to write the version into $PLIST"
note "$PLIST: CFBundleShortVersionString $VERSION, CFBundleVersion $BUILD"

# README states the version in prose: "Shout is at **v1.0.0**."
perl -0pi -e "s/Shout is at \*\*v[0-9][^*]*\*\*/Shout is at **v$VERSION**/" "$README"
grep -q "Shout is at \*\*v$VERSION\*\*" "$README" || die "failed to write the version into $README"
note "$README: version line updated"

# Changelog heading, plus a fresh empty [Unreleased] to collect the next cycle.
awk -v version="$VERSION" -v date="$DATE" -v mode="$MODE" '
    !done && mode == "promote-unreleased" && $0 ~ /^## \[Unreleased\]/ {
        print "## [Unreleased]"
        print ""
        print "## [" version "] — " date
        done = 1
        next
    }
    !done && mode == "date-existing" && index($0, "## [" version "]") == 1 {
        print "## [Unreleased]"
        print ""
        print "## [" version "] — " date
        done = 1
        next
    }
    { print }
    END { if (!done) exit 1 }
' "$CHANGELOG" > "$CHANGELOG.tmp" || die "failed to rewrite the $CHANGELOG heading"
mv "$CHANGELOG.tmp" "$CHANGELOG"
note "$CHANGELOG: [$VERSION] dated $DATE, fresh [Unreleased] opened"

# Link definitions: Unreleased compares against the new tag; the new version
# links to its own tag (first release) or to a diff against the previous one.
PREV="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?\]' "$CHANGELOG" \
        | sed -E 's/^## \[(.*)\]$/\1/' | sed -n 2p || true)"
if [[ -n "$PREV" ]]; then
    version_ref="$REPO_URL/compare/v$PREV...$TAG"
else
    version_ref="$REPO_URL/releases/tag/$TAG"
fi

body="$(grep -vE '^\[[^]]+\]: http' "$CHANGELOG")"
kept_refs="$(grep -E '^\[[^]]+\]: http' "$CHANGELOG" | grep -vE "^\[(Unreleased|$VERSION)\]: " || true)"
{
    printf '%s\n' "$body" | awk 'BEGIN { blank = 0 }
        { if ($0 ~ /[^[:space:]]/) { for (i = 0; i < blank; i++) print ""; blank = 0; print } else blank++ }'
    printf '\n[Unreleased]: %s/compare/%s...HEAD\n' "$REPO_URL" "$TAG"
    printf '[%s]: %s\n' "$VERSION" "$version_ref"
    [[ -n "$kept_refs" ]] && printf '%s\n' "$kept_refs"
} > "$CHANGELOG.tmp"
mv "$CHANGELOG.tmp" "$CHANGELOG"
note "$CHANGELOG: link definitions rewritten"

echo
git --no-pager diff --stat
echo

# ---- verify ----------------------------------------------------------------

if [[ -z "${SKIP_TESTS:-}" ]]; then
    echo "Running the test suite before tagging…"
    swift test >/dev/null || die "tests failed — not tagging a broken release (SKIP_TESTS=1 overrides)"
    note "tests pass"
else
    note "tests skipped (SKIP_TESTS=1)"
fi

if [[ -n "${DRY_RUN:-}" ]]; then
    echo
    echo "DRY_RUN: reverting the edits, nothing committed or tagged."
    git checkout -- "$PLIST" "$README" "$CHANGELOG"
    exit 0
fi

# ---- commit and tag --------------------------------------------------------

# The tag annotation carries this release's changelog section, so `git show`
# and `gh release create --notes-from-tag` both describe the release.
notes="$(awk -v version="$VERSION" '
    index($0, "## [" version "]") == 1 { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
' "$CHANGELOG")"

git add "$PLIST" "$README" "$CHANGELOG"
git commit -q -m "release: $TAG"
git tag -a "$TAG" -m "Shout $TAG" -m "$notes"

echo
echo "Committed $(git rev-parse --short HEAD) and tagged $TAG. Nothing pushed yet:"
echo
echo "  git push origin main --follow-tags"
echo "  gh release create $TAG --title \"Shout $TAG\" --notes-from-tag"
echo
echo "GPL-3.0 §6: if you ever attach a built .app or .dmg to that release, the"
echo "Corresponding Source must accompany it — GitHub's auto-generated source"
echo "archives on the release page satisfy that, so publish from the tag."
