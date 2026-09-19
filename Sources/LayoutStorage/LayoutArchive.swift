import Foundation
import Geometry

public enum ArchiveError: Error, Equatable {
    case oversized
    case unsupportedVersion(Int)
    case invalidDocument
    case duplicateLayoutID
    case missingLayout(UUID)
    case emptyLibrary
    case invalidDisplayKey
}

public struct LayoutCollection: Sendable, Equatable {
    public let layouts: [Layout]
    public let activeByDisplay: [String: UUID]

    public init(layouts: [Layout] = BuiltInLayouts.all, activeByDisplay: [String: UUID] = [:]) {
        self.layouts = layouts
        self.activeByDisplay = activeByDisplay
    }

    public func validate() throws {
        guard !layouts.isEmpty else { throw ArchiveError.emptyLibrary }
        var ids = Set<UUID>()
        for layout in layouts {
            guard ids.insert(layout.id).inserted else { throw ArchiveError.duplicateLayoutID }
            try layout.validate()
        }
        for (key, id) in activeByDisplay {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ArchiveError.invalidDisplayKey }
            guard ids.contains(id) else { throw ArchiveError.missingLayout(id) }
        }
    }

    public func committingPlacement(layoutID: UUID, displayKey: String, succeeded: Bool) throws -> LayoutCollection {
        guard succeeded else { return self }
        var active = activeByDisplay
        active[displayKey] = layoutID
        let updated = LayoutCollection(layouts: layouts, activeByDisplay: active)
        try updated.validate()
        return updated
    }
}

public enum LayoutArchive {
    public static let maximumBytes = 1_048_576

    private struct Header: Codable { let schemaVersion: Int }
    private struct Document: Codable {
        let schemaVersion: Int
        let layouts: [LayoutRecord]
        let activeByDisplay: [String: UUID]
    }
    private struct LayoutRecord: Codable {
        let id: UUID
        let name: String
        let inset: Double
        let gap: Double
        let nodes: [NodeRecord]
    }
    private struct NodeRecord: Codable {
        let kind: String
        var id: UUID?
        var name: String?
        var axis: String?
        var ratio: Double?
        var first: Int?
        var second: Int?
    }

    public static func encode(_ collection: LayoutCollection) throws -> Data {
        try collection.validate()
        let layouts = collection.layouts.map { layout in
            var nodes: [NodeRecord] = []
            func append(_ node: LayoutNode) -> Int {
                let index = nodes.count
                switch node {
                case let .zone(id, name): nodes.append(NodeRecord(kind: "zone", id: id, name: name))
                case let .split(axis, ratio, first, second):
                    nodes.append(NodeRecord(kind: "split"))
                    let firstIndex = append(first)
                    let secondIndex = append(second)
                    nodes[index] = NodeRecord(kind: "split", axis: axis == .vertical ? "vertical" : "horizontal",
                                              ratio: ratio, first: firstIndex, second: secondIndex)
                }
                return index
            }
            _ = append(layout.root)
            return LayoutRecord(id: layout.id, name: layout.name, inset: layout.inset, gap: layout.gap, nodes: nodes)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: 1, layouts: layouts, activeByDisplay: collection.activeByDisplay))
        guard data.count <= maximumBytes else { throw ArchiveError.oversized }
        return data
    }

    public static func decode(_ data: Data) throws -> LayoutCollection {
        guard data.count <= maximumBytes else { throw ArchiveError.oversized }
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw ArchiveError.invalidDocument }
        guard header.schemaVersion == 1 else { throw ArchiveError.unsupportedVersion(header.schemaVersion) }
        let document: Document
        do { document = try decoder.decode(Document.self, from: data) }
        catch { throw ArchiveError.invalidDocument }
        let layouts = try document.layouts.map { record in
            // Flat records bound decoding before any recursive domain tree is constructed.
            guard !record.nodes.isEmpty, record.nodes.count <= 23 else { throw ArchiveError.invalidDocument }
            var visited = Set<Int>()
            func build(_ index: Int, depth: Int) throws -> LayoutNode {
                guard depth <= 12, record.nodes.indices.contains(index), visited.insert(index).inserted else {
                    throw ArchiveError.invalidDocument
                }
                let node = record.nodes[index]
                switch node.kind {
                case "zone":
                    guard let id = node.id, let name = node.name,
                          node.axis == nil, node.ratio == nil, node.first == nil, node.second == nil else {
                        throw ArchiveError.invalidDocument
                    }
                    return .zone(id: id, name: name)
                case "split":
                    guard let axisName = node.axis, let ratio = node.ratio,
                          let first = node.first, let second = node.second,
                          node.id == nil, node.name == nil,
                          axisName == "vertical" || axisName == "horizontal" else { throw ArchiveError.invalidDocument }
                    return .split(axis: axisName == "vertical" ? .vertical : .horizontal, ratio: ratio,
                                  first: try build(first, depth: depth + 1), second: try build(second, depth: depth + 1))
                default: throw ArchiveError.invalidDocument
                }
            }
            let root = try build(0, depth: 1)
            guard visited.count == record.nodes.count else { throw ArchiveError.invalidDocument }
            return Layout(id: record.id, name: record.name, root: root, inset: record.inset, gap: record.gap)
        }
        let collection = LayoutCollection(layouts: layouts, activeByDisplay: document.activeByDisplay)
        try collection.validate()
        return collection
    }
}
