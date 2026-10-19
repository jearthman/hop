#!/usr/bin/env bash
# Prints the code-signing identity Hop builds should use, or nothing for ad-hoc.
# Uses $SIGN_ID if set, otherwise your Apple Development certificate (free Apple ID via
# Xcode). An Apple-issued certificate is what lets macOS keep Hop's Accessibility
# permission across updates; ad-hoc builds lose it every time.
set -euo pipefail

if [[ -n "${SIGN_ID:-}" ]]; then
  echo "$SIGN_ID"
  exit 0
fi

# Use the certificate's SHA-1 so an expired duplicate with the same name can't be picked.
security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $2; exit}'
