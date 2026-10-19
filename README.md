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

Hop only needs **Accessibility** permission. It never asks for Screen Recording or Input Monitoring, and it makes no network requests.

## Build

Requires Xcode (Swift 5.9+).

```bash
./build.sh
```

This runs the unit tests, builds a universal (Apple Silicon + Intel) binary for macOS 14 and later, assembles `build/Hop.app`, signs it and writes `build/Hop-1.0.0.dmg`. Set `VERSION=1.1.0` to change the version.

## Install on a Mac

1. Open the DMG and drag **Hop** to **Applications**.
2. The first time you open it, macOS blocks it because it is ad-hoc signed, not notarized. Go to **System Settings › Privacy & Security** and click **Open Anyway**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Hop.app
   ```
3. When prompted, turn on Hop in **System Settings › Privacy & Security › Accessibility**.
4. Optional: in the menu bar icon, turn on **Launch at Login**.

### After installing a new build

macOS ties the Accessibility grant to the app's code signature, and ad-hoc signatures change with every build. If Hop stops listing windows after an update, open **Privacy & Security › Accessibility**, remove Hop with the **–** button, and add it again (or toggle it off and on).

### Signing with a Developer ID (optional)

With a paid Apple developer account, the Gatekeeper and re-grant steps above go away:

```bash
xcrun notarytool store-credentials hop   # one time
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=hop ./build.sh
```

## How it works

- `Sources/HopCore/Matcher.swift` holds the ranking, in tiers: an app-name prefix or app acronym first, then a title or word prefix, then a cross-field acronym ("sl" matches Safari · Login), then a fuzzy subsequence. Ties go to the most recently used window. It is covered by `swift test`.
- `WindowCatalog` takes a fresh snapshot each time the panel opens. It reads every app's Accessibility window list in parallel and merges in windows on other Spaces, which it learns about from the window server's list and from a background element scan (the same technique AltTab uses). Nothing polls while idle.
- `FocusTracker` follows focused-window changes in every app, so recency stays right even when you switch windows without Hop.
- `Focuser` un-minimizes the window, makes it key through SkyLight (falling back to the public API), and raises it.
- Private APIs are resolved at runtime with `dlsym`. If a future macOS removes one, Hop falls back to the public API instead of crashing.
