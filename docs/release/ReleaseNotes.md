# WindowZones 0.3.0

A calmer layout bar, display-aware layouts, and more control over how WindowZones works.

- A wider smoky layout bar below the macOS menu bar, with smooth appearance, expansion and dismissal.
- A compact drag hint and a translucent preview of the destination zone.
- Adaptive presets: four on regular landscape displays, six on wide displays, and top/bottom halves, three rows or quarters on portrait displays.
- General, Controls, Exclusions and Permissions settings. Shortcut, drag modifier, drag and fill-assistant preferences persist between launches.
- Exclude apps from placement and fill suggestions while retaining Undo.
- English and Russian interface, following the macOS language setting.
- Improved keyboard navigation in settings and window suggestions.
- Expanded recognition of the Claude desktop title area. This specific compatibility fix still needs a confirmed physical drag after the change.

Existing untouched standard layout libraries migrate automatically. Custom libraries remain unchanged. Display-specific choices are retained where available.

68 automated tests passed locally. The updated drag animation and panel design were accepted by the user on the test Mac. This is an early release for Apple silicon and macOS 15 or later, primarily tested on macOS 27.0.1. Full VoiceOver acceptance, portrait and mixed-display physical drag checks, clean-profile setup, real login and the complete Spaces/sleep/disconnect matrix remain incomplete. Very fast drags and app minimum window sizes can affect placement. No custom layout editor or Intel build yet.

Use Check for Updates in WindowZones, or download WindowZones-0.3.0-arm64.zip. Release archives are Developer ID signed and notarized by Apple.

Report issues at https://github.com/shumer/WindowZones/issues with the app, macOS version, display setup and reproduction steps. Remove private content from screenshots.
