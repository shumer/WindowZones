import Foundation

public struct Preferences {
    public enum Shortcut: String, CaseIterable, Sendable {
        case controlOptionSpace, controlShiftSpace
    }
    public enum DragModifier: String, CaseIterable, Sendable {
        case shift, option, control
    }
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var dragEnabled: Bool {
        get { defaults.object(forKey: "dragEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "dragEnabled") }
    }
    public var fillEnabled: Bool {
        get { defaults.object(forKey: "fillAssistantEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "fillAssistantEnabled") }
    }
    public var shortcut: Shortcut {
        get { Shortcut(rawValue: defaults.string(forKey: "shortcut") ?? "") ?? .controlOptionSpace }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "shortcut") }
    }
    public var dragModifier: DragModifier {
        get { DragModifier(rawValue: defaults.string(forKey: "dragModifier") ?? "") ?? .shift }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "dragModifier") }
    }
    public var excludedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedBundleIDs") ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: "excludedBundleIDs") }
    }
    public func excludes(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }
}
