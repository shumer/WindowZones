import AppKit
import ColorSync

extension Display {
    @MainActor var storageKey: String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    @MainActor func uniqueStorageKey(in displays: [Display]) -> String? {
        guard let key = storageKey,
              displays.filter({ $0.storageKey == key }).count == 1 else { return nil }
        return key
    }
}
