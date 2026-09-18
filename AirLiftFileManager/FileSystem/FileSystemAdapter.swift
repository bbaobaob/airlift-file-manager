import Foundation

/// Adapter exposing AirLift's capability as a file system.
///
/// Reality check (verified against the upstream repository):
/// AirLift executes on a paired Mac (MobileDevice.framework + AirTrafficHost.framework)
/// and drives device-side system daemons (streaming_zip_conduit, afc, atc).
/// A sandboxed iOS app cannot reach any of those components, so there is no
/// functional AirLift-backed file system available in-process today.
///
/// This adapter therefore reports `unsupported` with precise reasons instead of
/// pretending to serve /var/mobile content. It is the seam where a future
/// host-relay implementation would plug in.
struct AirLiftFileSystemAdapter: FileSystemService {
    static let shared = AirLiftFileSystemAdapter()

    let scopeRoots: [URL] = []
    let capabilities: FileSystemCapabilities = .none

    private static let reason =
        "AirLift writes files from the paired Mac side (AirTrafficHost.framework). " +
        "No in-app AirLift file system exists until a host relay is implemented."

    func listDirectory(at url: URL, includeHidden: Bool) async throws -> [FileItem] {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func fileExists(at url: URL) async -> Bool { false }

    func getFileMetadata(at url: URL) async throws -> FileItem {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func createDirectory(at url: URL) async throws {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func copyItem(at source: URL, to destination: URL, replaceConfirmed: Bool) async throws {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func moveItem(at source: URL, to destination: URL, replaceConfirmed: Bool) async throws {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func deleteItem(at url: URL) async throws {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func renameItem(at url: URL, to newName: String) async throws -> URL {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func compressItems(at urls: [URL], into archiveURL: URL) async throws {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) async throws {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }

    func replaceItem(at target: URL, with source: URL) async throws {
        throw FileSystemError.unsupportedOperation(Self.reason)
    }
}
