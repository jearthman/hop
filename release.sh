#!/usr/bin/env bash
# Builds and publishes a GitHub release that installed copies of Hop will offer as an update.
#
#   ./release.sh 1.2.0                 release notes generated from commits
#   ./release.sh 1.2.0 notes.md        release notes from a file
set -euo pipefail

VERSION="${1:?usage: ./release.sh <version> [notes-file]}"
NOTES="${2:-}"
VERSION="${VERSION#v}"
cd "$(dirname "$0")"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || { echo "Push your commits first (HEAD differs from upstream)." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "v$VERSION already exists." >&2
  exit 1
fi

# Installed copies only accept updates signed with the same certificate, so never release ad-hoc.
if [[ -z "$(scripts/signing-identity.sh)" ]]; then
  echo "No signing certificate found. Create an Apple Development certificate in Xcode (see README)." >&2
  exit 1
fi

VERSION="$VERSION" ./build.sh

ARGS=(--title "Hop $VERSION" --target "$(git rev-parse HEAD)")
if [[ -n "$NOTES" ]]; then ARGS+=(--notes-file "$NOTES"); else ARGS+=(--generate-notes); fi
gh release create "v$VERSION" "build/Hop-$VERSION.dmg" "build/Hop-$VERSION.zip" "${ARGS[@]}"
echo "Published v$VERSION. Running copies of Hop will offer it within a day, or right away via Check for Updates…"
