import Foundation

/// Filesystem abstraction. UI never touches FileManager directly.
/// Every call returns a typed result or throws a typed error; nothing crashes the app.
protocol FileSystemService: Sendable {
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
    /// Root paths this service is permitted to touch.
    var scopeRoots: [URL] { get }
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
}
