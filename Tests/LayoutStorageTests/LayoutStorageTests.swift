import Foundation
import Geometry
import Testing
@testable import LayoutStorage

struct LayoutStorageTests {
    private func collection(_ name: String) -> LayoutCollection {
        let layout = Layout(name: name, root: .split(axis: .vertical, ratio: 0.3,
                            first: .zone(id: UUID(), name: "Левая"),
                            second: .zone(id: UUID(), name: "Right")), inset: 9.5, gap: 12)
        return LayoutCollection(layouts: [layout], activeByDisplay: ["display-1": layout.id])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowZones-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func futureArchive(_ collection: LayoutCollection) throws -> Data {
        let data = try LayoutArchive.encode(collection)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 999
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func roundTripPreservesTreeIdentityNamesAndDisplaySelection() throws {
        let original = collection("Работа 🖥")
        let data = try LayoutArchive.encode(original)
        #expect(try LayoutArchive.decode(data) == original)
        #expect(try LayoutArchive.decode(LayoutArchive.encode(LayoutCollection())) == LayoutCollection())
    }

    @Test func unknownVersionAndOversizedInputAreRejected() throws {
        #expect(throws: ArchiveError.unsupportedVersion(999)) {
            try LayoutArchive.decode(futureArchive(collection("Future")))
        }
        let oversized = Data(repeating: 32, count: LayoutArchive.maximumBytes + 1)
        #expect(throws: ArchiveError.oversized) { try LayoutArchive.decode(oversized) }
        #expect(throws: ArchiveError.invalidDocument) { try LayoutArchive.decode(Data("{".utf8)) }
    }

    @Test func duplicateLayoutsAndMissingActiveReferenceAreRejected() throws {
        let original = collection("Work")
        let first = try #require(original.layouts.first)
        #expect(throws: ArchiveError.duplicateLayoutID) {
            try LayoutArchive.encode(LayoutCollection(layouts: [first, first]))
        }
        let missing = UUID()
        #expect(throws: ArchiveError.missingLayout(missing)) {
            try LayoutArchive.encode(LayoutCollection(layouts: [first], activeByDisplay: ["display": missing]))
        }
        #expect(throws: ArchiveError.emptyLibrary) {
            try LayoutArchive.encode(LayoutCollection(layouts: []))
        }
        #expect(throws: ArchiveError.invalidDisplayKey) {
            try LayoutArchive.encode(LayoutCollection(layouts: [first], activeByDisplay: ["": first.id]))
        }
        var object = try #require(JSONSerialization.jsonObject(with: LayoutArchive.encode(original)) as? [String: Any])
        let layouts = try #require(object["layouts"] as? [Any])
        object["layouts"] = layouts + layouts
        let duplicatedData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ArchiveError.duplicateLayoutID) { try LayoutArchive.decode(duplicatedData) }
    }

    @Test func placementCommitsOnlyOnSuccessAndPreservesOtherDisplays() throws {
        let first = try #require(collection("First").layouts.first)
        let second = try #require(collection("Second").layouts.first)
        let original = LayoutCollection(layouts: [first, second], activeByDisplay: ["one": first.id, "two": first.id])
        let failed = try original.committingPlacement(layoutID: second.id, displayKey: "one", succeeded: false)
        #expect(failed == original)
        let successful = try original.committingPlacement(layoutID: second.id, displayKey: "one", succeeded: true)
        #expect(successful.activeByDisplay == ["one": second.id, "two": first.id])
        #expect(successful.layouts == original.layouts)
        #expect(original.activeByDisplay["one"] == first.id)
        let missing = UUID()
        #expect(throws: ArchiveError.missingLayout(missing)) {
            try original.committingPlacement(layoutID: missing, displayKey: "one", succeeded: true)
        }
    }

    @Test func freshLoadUsesDefaultsWithoutWritingFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await LayoutStore(directory: directory).load()
        #expect(result.source == .defaults)
        #expect(result.collection == LayoutCollection())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func repeatedSavesKeepPreviousValidPrimaryAsBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        let first = collection("First")
        let second = collection("Second")
        let third = collection("Third")
        try await store.save(first)
        try await store.save(second)
        try await store.save(third)
        let current = try await store.load()
        #expect(current.source == .primary)
        #expect(current.collection == third)
        let backup = try Data(contentsOf: directory.appendingPathComponent("layouts.backup.json"))
        #expect(try LayoutArchive.decode(backup) == second)
    }

    @Test func corruptPrimaryFallsBackAndNextSavePreservesValidBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        let first = collection("First")
        let second = collection("Second")
        try await store.save(first)
        try await store.save(second)
        let primaryURL = directory.appendingPathComponent("layouts.json")
        let backupURL = directory.appendingPathComponent("layouts.backup.json")
        try Data("interrupted json {".utf8).write(to: primaryURL)
        let recovered = try await store.load()
        #expect(recovered.source == .backup)
        #expect(recovered.collection == first)
        try await store.save(second)
        #expect(try LayoutArchive.decode(Data(contentsOf: backupURL)) == first)
        #expect(try LayoutArchive.decode(Data(contentsOf: primaryURL)) == second)
    }

    @Test func twoCorruptFilesFailWithoutReplacingEitherWithDefaults() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = Data("broken".utf8)
        let primary = directory.appendingPathComponent("layouts.json")
        let backup = directory.appendingPathComponent("layouts.backup.json")
        try corrupt.write(to: primary)
        try corrupt.write(to: backup)
        await #expect(throws: ArchiveError.self) { try await LayoutStore(directory: directory).load() }
        #expect(try Data(contentsOf: primary) == corrupt)
        #expect(try Data(contentsOf: backup) == corrupt)
    }

    @Test func failedValidationCannotReplacePrimaryOrBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        try await store.save(collection("First"))
        try await store.save(collection("Second"))
        let primaryURL = directory.appendingPathComponent("layouts.json")
        let backupURL = directory.appendingPathComponent("layouts.backup.json")
        let primaryBefore = try Data(contentsOf: primaryURL)
        let backupBefore = try Data(contentsOf: backupURL)
        await #expect(throws: ArchiveError.emptyLibrary) { try await store.save(LayoutCollection(layouts: [])) }
        #expect(try Data(contentsOf: primaryURL) == primaryBefore)
        #expect(try Data(contentsOf: backupURL) == backupBefore)
    }

    @Test func futurePrimaryCannotFallBackOrBeOverwritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        let original = collection("Valid")
        try await store.save(original)
        try await store.save(collection("Next"))
        let primary = directory.appendingPathComponent("layouts.json")
        let backup = directory.appendingPathComponent("layouts.backup.json")
        let future = try futureArchive(original)
        let backupBefore = try Data(contentsOf: backup)
        try future.write(to: primary)
        await #expect(throws: ArchiveError.unsupportedVersion(999)) { try await store.load() }
        await #expect(throws: ArchiveError.unsupportedVersion(999)) { try await store.save(original) }
        #expect(try Data(contentsOf: primary) == future)
        #expect(try Data(contentsOf: backup) == backupBefore)
    }

    @Test func futureBackupIsProtectedEvenWhenPrimaryIsValid() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        let original = collection("Current")
        try await store.save(original)
        let primary = directory.appendingPathComponent("layouts.json")
        let backup = directory.appendingPathComponent("layouts.backup.json")
        let primaryBefore = try Data(contentsOf: primary)
        var futureObject = try #require(JSONSerialization.jsonObject(with: primaryBefore) as? [String: Any])
        futureObject["schemaVersion"] = 2
        let futureBackup = try JSONSerialization.data(withJSONObject: futureObject)
        try futureBackup.write(to: backup)
        await #expect(throws: ArchiveError.unsupportedVersion(2)) {
            try await store.save(collection("Replacement"))
        }
        #expect(try Data(contentsOf: primary) == primaryBefore)
        #expect(try Data(contentsOf: backup) == futureBackup)
    }

    @Test func decoderRejectsCyclesSharedChildrenUnreachableNodesAndInvalidIndices() throws {
        let encoded = try LayoutArchive.encode(collection("Graph validation"))
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for malformedCase in 0..<5 {
            var document = original
            var layouts = try #require(document["layouts"] as? [[String: Any]])
            var record = try #require(layouts.first)
            var nodes = try #require(record["nodes"] as? [[String: Any]])
            #expect(nodes.count == 3)
            #expect(nodes[0]["kind"] as? String == "split")
            switch malformedCase {
            case 0:
                nodes[0]["first"] = 0
            case 1:
                nodes[0]["second"] = nodes[0]["first"]
            case 2:
                nodes.append(["kind": "zone", "id": UUID().uuidString, "name": "Unreachable"])
            case 3:
                nodes[0]["second"] = nodes.count
            default:
                nodes[0]["first"] = -1
            }
            record["nodes"] = nodes
            layouts[0] = record
            document["layouts"] = layouts
            let malformed = try JSONSerialization.data(withJSONObject: document)
            #expect(throws: ArchiveError.invalidDocument) { try LayoutArchive.decode(malformed) }
        }
    }

    @Test func unfinishedUnrelatedTemporaryFileDoesNotAffectValidPrimary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        let original = collection("Saved")
        try await store.save(original)
        let primary = directory.appendingPathComponent("layouts.json")
        let primaryBefore = try Data(contentsOf: primary)
        let temporary = directory.appendingPathComponent(".layouts-pending-\(UUID().uuidString).tmp")
        let unfinished = Data("{\"schemaVersion\":1,\"layouts\":[".utf8)
        try unfinished.write(to: temporary)
        let loaded = try await store.load()
        #expect(loaded.source == .primary)
        #expect(loaded.collection == original)
        #expect(try Data(contentsOf: primary) == primaryBefore)
        #expect(try Data(contentsOf: temporary) == unfinished)
    }
}
