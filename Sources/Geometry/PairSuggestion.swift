import Foundation

public enum PairSuggestion {
    public static let layoutID = UUID(uuidString: "575A0000-0000-4000-8000-000000000011")!
    public static let layout = Layout(id: layoutID, name: "Suggested pair", root: BuiltInLayouts.halves.root)

    // Input order represents recent use; an already aligned neighbor takes priority.
    public static func choose(frames: [CGRect], zones: [CGRect]) -> (candidate: Int, neighborZone: Int)? {
        guard zones.count == 2 else { return nil }
        for (index, frame) in frames.enumerated() {
            if let zone = zones.firstIndex(where: { FillSession.accepts(actual: frame, target: $0) }) {
                return (index, zone)
            }
        }
        return frames.isEmpty ? nil : (0, 1)
    }
}
