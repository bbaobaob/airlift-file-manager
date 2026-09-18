import Foundation

/// Filesystem abstraction. UI never touches FileManager directly.
/// Every call returns a typed result or throws a typed error; nothing crashes the app.
protocol FileSystemService: Sendable {
    var scopeRoots: [URL] { get }
    var capabilities: FileSystemCapabilities { get }
    func listDirectory(at url: URL, includeHidden: Bool) async throws -> [FileItem]
    func fileExists(at url: URL) async -> Bool
    func getFileMetadata(at url: URL) async throws -> FileItem
    func createDirectory(at url: URL) async throws
    func copyItem(at source: URL, to destination: URL, replaceConfirmed: Bool) async throws
    func moveItem(at source: URL, to destination: URL, replaceConfirmed: Bool) async throws
    func deleteItem(at url: URL) async throws
    func renameItem(at url: URL, to newName: String) async throws -> URL
    func compressItems(at urls: [URL], into archiveURL: URL) async throws
    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) async throws
    func replaceItem(at target: URL, with source: URL) async throws
}

extension FileSystemService {
    /// Guards that a path stays inside one of the permitted roots.
    func validateInScope(_ url: URL) throws {
        let standardized = url.standardizedFileURL.path
        let inScope = scopeRoots.contains { root in
            standardized == root.standardizedFileURL.path ||
            standardized.hasPrefix(root.standardizedFileURL.path + "/")
        }
        guard inScope else {
            throw FileSystemError.outsideScope(url.path)
        }
    }

    func assertDestinationFree(_ destination: URL, replaceConfirmed: Bool) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard replaceConfirmed else {
                throw FileSystemError.replaceNotConfirmed(destination.path)
            }
        }
    }

    /// Safe destination name for copy/move: if the name collides, appends " 2", " 3"...
    func uniqueDestination(_ base: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return base }
        let dir = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
