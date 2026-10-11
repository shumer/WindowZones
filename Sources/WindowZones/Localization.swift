import Foundation
import Geometry

func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: arguments)
}

extension Layout {
    func localizedZoneName(_ value: String) -> String {
        guard (BuiltInLayouts.all + BuiltInLayouts.legacy).contains(where: { $0 == self }) else { return value }
        return L(value)
    }
    var displayName: String {
        // Translate only unmodified built-in names, preserving user-authored names.
        guard (BuiltInLayouts.all + BuiltInLayouts.legacy).contains(where: { $0.id == id && $0.name == name }) else { return name }
        return L(name)
    }
}
