# WindowZones 0.2.1

Fixes the missing layout bar when dragging Firefox or Vivaldi by empty space beside their tabs.

- Firefox: recognize empty gaps in the tab strip while excluding the tabs and buttons themselves.
- Vivaldi: recognize title areas nested inside a scrolling container.
- Window movement must still be confirmed before the layout bar appears.

Both browser fixes were confirmed by physical window dragging on the test Mac. 62 automated tests passed locally. This remains an early release for Apple silicon, macOS 15 or later; the primary test system is macOS 27.0.1.

Use Check for Updates in WindowZones, or download WindowZones-0.2.1-arm64.zip and replace the app in Applications. Release archives are Developer ID signed and notarized by Apple.

Known limitations remain: very fast drags may be missed, some apps enforce minimum window sizes, Chrome Accessibility availability varies, and minimized Telegram windows are not separately verified. The full Spaces, sleep, monitor-disconnect and clean-profile matrix is incomplete. Physical negative tests for dragging tabs and resizing were not repeated for this patch. No custom layout editor or Intel build yet.

Report issues at https://github.com/shumer/WindowZones/issues with the app, macOS version, display setup and reproduction steps. Remove private content from screenshots.
