# WindowZones 0.2.0

An early release for colleagues on Apple silicon, macOS 15 or later. The main local test environment is macOS 27.0.1. The app interface is currently in Russian.

## What's new

- Five layouts: 50/50 columns, 75/25 columns, thirds, top/bottom halves and four quarters.
- After placing a window, choose window cards directly inside the next free zone. Skip or press Escape to stop.
- Minimized windows can appear as cards and are restored only when selected. Screen Recording permission enables optional thumbnails; without it, app icons remain available.
- Better title-bar recognition for Finder and Slack, more reliable size settling and cross-display rollback.
- A custom menu bar icon showing a window and its destination zone.

## Install and try

Download WindowZones-0.2.0-arm64.zip, unzip it and place WindowZones.app in Applications. Launch it and enable Accessibility for that copy. Drag a regular window by an empty part of its title bar toward the top of the display, choose a zone and release. Alternatively use Control+Option+Space. Undo is in the WindowZones menu.

This release is available through Check for Updates in WindowZones and as a direct download. It is Developer ID signed and notarized by Apple. Manual replacement of 0.1.0 with this exact archive preserved the layout library and Accessibility permission on the test Mac.

## Known limitations

- Chrome may not expose a usable Accessibility window. Minimized Telegram windows are not separately verified.
- Very fast drag starts may be missed. Fullscreen, Spaces, sleep, permission revocation and monitor-disconnect combinations need more testing.
- Minimum window sizes can prevent an exact fit. Undo after restoring a minimized window restores its geometry but does not minimize it again.
- Window discovery has a bounded scan time; slow apps may be absent from suggestions.
- Clean-profile first launch, a real login cycle and the automatic Sparkle update path from 0.1.0 to 0.2.0 are not yet verified.
- No custom layout editor, Intel build or full English localization yet.

Please report the affected app, macOS version, display setup and reproduction steps at https://github.com/shumer/WindowZones/issues. Remove private content from screenshots.
