import Foundation
import Testing
@testable import LayoutStorage

struct PreferencesTests {
    @Test func defaultsPersistenceAndInvalidValues() throws {
        let name = "WindowZones-preferences-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.dragEnabled && prefs.fillEnabled)
        #expect(prefs.shortcut == .controlOptionSpace && prefs.dragModifier == .shift)
        #expect(!prefs.excludes(nil))
        prefs.dragEnabled = false
        prefs.fillEnabled = false
        prefs.shortcut = .controlShiftSpace
        prefs.dragModifier = .option
        prefs.excludedBundleIDs = ["com.apple.finder"]
        let restored = Preferences(defaults: defaults)
        #expect(!restored.dragEnabled && !restored.fillEnabled)
        #expect(restored.shortcut == .controlShiftSpace && restored.dragModifier == .option)
        #expect(restored.excludes("com.apple.finder"))
        #expect(!restored.excludes("com.apple.Safari"))
        defaults.set("unknown", forKey: "shortcut")
        defaults.set("unknown", forKey: "dragModifier")
        #expect(restored.shortcut == .controlOptionSpace && restored.dragModifier == .shift)
        restored.excludedBundleIDs = []
        #expect(!prefs.excludes("com.apple.finder"))
    }
}
