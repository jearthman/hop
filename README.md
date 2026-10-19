# Hop

A personal, search-first window switcher for macOS, modelled on Panehop's public feature set.

Press **⌥Space**, type a few letters of an app name or window title, and press **Return**.

| Key | Action |
| --- | --- |
| ⌥Space | Open / close the switcher |
| type | Filter by app name and window title (fuzzy; acronyms like `vsc` work) |
| ↑ ↓, Tab / ⇧Tab, ⌃N / ⌃P | Move the selection |
| Return or click | Switch to the window (un-minimizes it and jumps Spaces if needed) |
| ⌘1 … ⌘9 | Switch straight to that row |
| Esc | Close and return to where you were |

When the search field is empty, the previous window is preselected, so pressing ⌥Space and then Return flips between your last two windows.

Hop only needs **Accessibility** permission. It never asks for Screen Recording or Input Monitoring. Its only network request is a daily check of this repo's latest GitHub release.

## Install on a Mac

1. Download the latest `Hop-x.y.z.dmg` from [Releases](https://github.com/jearthman/hop/releases), open it and drag **Hop** to **Applications**.
2. The first time you open it, macOS blocks it because it isn't notarized. Go to **System Settings › Privacy & Security** and click **Open Anyway**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Hop.app
   ```
3. When prompted, turn on Hop in **System Settings › Privacy & Security › Accessibility**.
4. Optional: in the menu bar icon, turn on **Launch at Login**.

## Updates

Hop checks GitHub once a day, and **Check for Updates…** in the menu bar icon checks right away. When a newer release exists, a window shows its release notes with **Install Update**, **Remind Me Later** and **Skip This Version**. Choosing Install Update:

1. downloads `Hop-x.y.z.zip` from the release, with a progress bar
2. checks it against the SHA-256 digest GitHub publishes for the file
3. checks that the new app is signed with the same certificate and bundle identifier as the running one, and that its version matches the release
4. quits, swaps the new app into place (restoring the old one if the swap fails) and reopens Hop.

Because releases are signed with the same Apple certificate, the Accessibility permission carries over and Hop keeps working after the restart.

## Build and release

Requires Xcode and an **Apple Development** certificate, which is free with any Apple ID: in Xcode open **Settings › Accounts**, add your Apple ID, select your *Personal Team*, then **Manage Certificates… › + › Apple Development**. If `security find-identity -v -p codesigning` doesn't list it as valid, install Apple's [WWDR G3 intermediate](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer).

```bash
./build.sh                  # tests, then build/Hop-<version>.dmg and .zip
VERSION=1.2.0 ./build.sh    # set the version
./release.sh 1.2.0          # build and publish GitHub release v1.2.0 (notes from commits)
./release.sh 1.2.0 notes.md # …with your own release notes
```

`build.sh` runs the unit tests, builds a universal (Apple Silicon + Intel) app for macOS 14 and later, and signs it with the identity `scripts/signing-identity.sh` picks (`SIGN_ID` overrides it). It writes a DMG for manual installs and a zip for in-app updates, and leaves no loose `Hop.app` behind, so Spotlight only finds the installed copy. `release.sh` refuses to publish with uncommitted or unpushed changes, or without a signing certificate.

To test an update locally, serve a JSON file shaped like GitHub's release API and point Hop at it: `open /Applications/Hop.app --args -UpdateFeedURL http://127.0.0.1:8000/latest.json`.

With a paid Apple Developer account you can also notarize, which removes the "Open Anyway" step:

```bash
xcrun notarytool store-credentials hop   # one time
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=hop ./build.sh
```

### If Hop keeps asking for Accessibility

macOS can hold on to a stale permission record from an older ad-hoc build. When that happens, removing and re-adding Hop in System Settings doesn't help. Reset Hop's record, reopen Hop and turn it on when prompted:

```bash
tccutil reset Accessibility com.jamesearthman.hop
```

## How it works

- `Sources/HopCore/Matcher.swift` holds the ranking, in tiers: an app-name prefix or app acronym first, then a title or word prefix, then a cross-field acronym ("sl" matches Safari · Login), then runs that each start a word ("goch" matches Google Chrome) or a plain substring. Letters scattered mid-word don't match. Ties go to the most recently used window. It is covered by `swift test`.
- `WindowCatalog` takes a fresh snapshot each time the panel opens. It reads every app's Accessibility window list in parallel and merges in windows on other Spaces, which it learns about from the window server's list and from a background element scan (the same technique AltTab uses). Nothing polls while idle.
- `FocusTracker` follows focused-window changes in every app, so recency stays right even when you switch windows without Hop.
- `Focuser` un-minimizes the window, makes it key through SkyLight (falling back to the public API), and raises it.
- Private APIs are resolved at runtime with `dlsym`. If a future macOS removes one, Hop falls back to the public API instead of crashing.
- `Updater` and `UpdateWindowController` run the update flow. `UpdateInstaller` downloads, verifies and stages the new app, then hands off to a small shell helper that waits for Hop to quit before swapping the bundles. Updates use the zip because mounting a DMG from inside an app trips macOS's removable-volume privacy check.
