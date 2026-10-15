# WindowZones 0.4.0

A smoother floating layout panel and suggested window pairs.

- The wide drag indicator now floats below the menu bar with rounded corners on every side and a neutral graphite surface.
- The panel expands smoothly without stretching the layout miniatures. Reduced Motion and increased contrast remain supported.
- A suggested 50/50 pair can appear before the regular layouts, showing the neighboring app icon. Drop into its empty half to arrange both windows.
- Suggestions prefer an eligible window already in a half, then a recently active app on the same screen. Minimized windows and excluded apps are not suggested.
- Undo can restore both windows from the last pair placement. Failed pair placement attempts to restore the affected windows.
- Regular layouts and the existing fill assistant remain available.

71 automated tests passed locally. The user accepted the floating panel appearance on the test Mac. Suggested pairs are an early feature: full physical placement, grouped Undo, partial failures and Space-switch acceptance remain unverified. A suggestion may be omitted if its window scan cannot finish before the panel opens.

Apple silicon, macOS 15 or later. Developer ID signed and notarized by Apple. Existing early-release limitations still apply, including app minimum window sizes and incomplete mixed-display and lifecycle testing.

Use Check for Updates in WindowZones, or download WindowZones-0.4.0-arm64.zip.

Report issues at https://github.com/shumer/WindowZones/issues. Remove private content from screenshots.
