import Foundation

/// Read-only view of a Mac-side file listing snapshot (TetherResult companion JSON).
/// - list() returns entries parsed from snapshot JSON.
/// - write/read-through/delete ALWAYS throw UnsupportedOnDevice.
/// - Any access to /var/mobile/* is marked Requires Mac / UnsupportedOnDevice.
///   This type never touches /var/mobile/* on-device.
final class TetheredReadOnlyService: FileSystemService {
    private var snapshot: [FileEntry]

    init(snapshot: [FileEntry] = []) {
        self.snapshot = snapshot
    }

    init(snapshotJSON: Data) throws {
        struct DTO: Codable { var name: String; var path: String; var isDirectory: Bool; var size: Int64; var modified: Date }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let dtos = try dec.decode([DTO].self, from: snapshotJSON)
        snapshot = dtos.map { FileEntry(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified) }
    }

    func list(path: String) throws -> [FileEntry] {
        if path.contains("/var/mobile") {
            throw FileSystemError.requiresMac("Listing /var/mobile/* requires Mac tether; on-device = UnsupportedOnDevice.")
        }
        if path.contains("..") { throw FileSystemError.pathTraversalBlocked }
        let prefix = path == "/" || path.isEmpty ? "/" : path
        return snapshot.filter { $0.path.hasPrefix(prefix) }
    }

    func read(path: String) throws -> Data {
        throw FileSystemError.unsupportedOnDevice("Read-through to tethered device is not supported on-device. Requires Mac.")
    }

    func write(path: String, data: Data) throws {
        throw FileSystemError.unsupportedOnDevice("Write to tethered path is not supported on-device.")
    }

    func delete(path: String) throws {
        throw FileSystemError.unsupportedOnDevice("Delete on tethered path is not supported on-device.")
    }

    func makeDirectory(path: String) throws {
        throw FileSystemError.unsupportedOnDevice("Mkdir on tethered path is not supported on-device.")
    }
}
