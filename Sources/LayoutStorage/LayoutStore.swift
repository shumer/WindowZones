import Foundation

public enum LayoutLoadSource: Sendable { case primary, backup, defaults }

public struct LayoutLoadResult: Sendable {
    public let collection: LayoutCollection
    public let source: LayoutLoadSource
}

public actor LayoutStore {
    public let directory: URL
    private var primary: URL { directory.appendingPathComponent("layouts.json") }
    private var backup: URL { directory.appendingPathComponent("layouts.backup.json") }

    public init(directory: URL) { self.directory = directory }

    public static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false).appendingPathComponent("WindowZones", isDirectory: true)
    }

    private func read(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= LayoutArchive.maximumBytes {
            let remaining = LayoutArchive.maximumBytes + 1 - data.count
            guard let chunk = try file.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= LayoutArchive.maximumBytes else { throw ArchiveError.oversized }
        return data
    }

    public func load() throws -> LayoutLoadResult {
        let manager = FileManager.default
        let hasPrimary = manager.fileExists(atPath: primary.path)
        let hasBackup = manager.fileExists(atPath: backup.path)
        if !hasPrimary && !hasBackup { return LayoutLoadResult(collection: LayoutCollection(), source: .defaults) }
        if hasPrimary {
            do { return LayoutLoadResult(collection: try LayoutArchive.decode(read(primary)), source: .primary) }
            catch ArchiveError.unsupportedVersion(let version) { throw ArchiveError.unsupportedVersion(version) }
            catch { if !hasBackup { throw error } }
        }
        return LayoutLoadResult(collection: try LayoutArchive.decode(read(backup)), source: .backup)
    }

    public func save(_ collection: LayoutCollection) throws {
        let data = try LayoutArchive.encode(collection)
        let manager = FileManager.default
        if manager.fileExists(atPath: backup.path) {
            do { _ = try LayoutArchive.decode(read(backup)) }
            catch ArchiveError.unsupportedVersion(let version) { throw ArchiveError.unsupportedVersion(version) }
            catch {
                // A valid primary can repair a corrupt backup, but cannot overwrite a newer schema.
            }
        }
        var previous: Data?
        if manager.fileExists(atPath: primary.path) {
            do {
                let candidate = try read(primary)
                _ = try LayoutArchive.decode(candidate)
                previous = candidate
            } catch ArchiveError.unsupportedVersion(let version) { throw ArchiveError.unsupportedVersion(version) }
            catch {
                // A corrupt primary must never replace the last valid backup.
                if manager.fileExists(atPath: backup.path) { _ = try LayoutArchive.decode(read(backup)) }
                else { throw error }
            }
        } else if manager.fileExists(atPath: backup.path) {
            _ = try LayoutArchive.decode(read(backup))
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let previous { try previous.write(to: backup, options: .atomic) }
        try data.write(to: primary, options: .atomic)
    }
}
