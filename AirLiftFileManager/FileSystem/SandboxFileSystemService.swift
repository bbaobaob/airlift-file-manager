import Foundation

/// Real FileManager-backed implementation over the app sandbox.
/// All errors are surfaced as typed throws; no call can crash the host app.
struct SandboxFileSystemService: FileSystemService {
    let scopeRoots: [URL]

    init(scopeRoots: [URL]? = nil) {
        if let scopeRoots {
            self.scopeRoots = scopeRoots
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.scopeRoots = [docs.deletingLastPathComponent()]
        }
    }

    func listDirectory(at url: URL, includeHidden: Bool) async throws -> [FileItem] {
        try validateInScope(url)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw FileSystemError.notFound(url.path)
        }
        guard isDirectory.boolValue else {
            throw FileSystemError.invalidDestination("\(url.path) is not a directory")
        }
        var items: [FileItem] = []
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey,
                                             .contentModificationDateKey,
                                             .creationDateKey, .isHiddenKey],
                options: [])
            for child in contents {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                                 .contentModificationDateKey,
                                                                 .creationDateKey, .isHiddenKey])
                let hidden = values?.isHidden ?? child.lastPathComponent.hasPrefix(".")
                if hidden && !includeHidden { continue }
                items.append(FileItem(
                    url: child,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modificationDate: values?.contentModificationDate,
                    creationDate: values?.creationDate,
                    posixPermissions: nil,
                    isHidden: hidden))
            }
        } catch let error as FileSystemError {
            throw error
        } catch let nsError as NSError where nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError {
                throw FileSystemError.permissionDenied(url.path)
            }
            throw FileSystemError.underlying(nsError.localizedDescription)
        } catch {
            throw FileSystemError.underlying(error.localizedDescription)
        }
        AppLogger.fs.debug("listDirectory \(url.lastPathComponent) -> \(items.count) items")
        return items
    }

    func fileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func getFileMetadata(at url: URL) async throws -> FileItem {
        try validateInScope(url)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw FileSystemError.notFound(url.path)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        let created = attributes?[.creationDate] as? Date
        let permissions = (attributes?[.posixPermissions] as? NSNumber).map { $0.intValue }
        let hidden = url.lastPathComponent.hasPrefix(".")
        return FileItem(url: url, isDirectory: isDirectory.boolValue, size: size,
                        modificationDate: modified, creationDate: created,
                        posixPermissions: permissions, isHidden: hidden)
    }

    func createDirectory(at url: URL) async throws {
        try validateInScope(url)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            AppLogger.fs.info("createDirectory \(url.lastPathComponent)")
        } catch let nsError as NSError {
            throw map(nsError, path: url.path)
        }
    }

    func copyItem(at source: URL, to destination: URL, replaceConfirmed: Bool) async throws {
        try validateInScope(source)
        try validateInScope(destination)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FileSystemError.notFound(source.path)
        }
        try assertDestinationFree(destination, replaceConfirmed: replaceConfirmed)
        if replaceConfirmed {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            AppLogger.fs.info("copy \(source.lastPathComponent) -> \(destination.lastPathComponent)")
        } catch let nsError as NSError {
            throw map(nsError, path: destination.path)
        }
    }

    func moveItem(at source: URL, to destination: URL, replaceConfirmed: Bool) async throws {
        try validateInScope(source)
        try validateInScope(destination)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FileSystemError.notFound(source.path)
        }
        try assertDestinationFree(destination, replaceConfirmed: replaceConfirmed)
        if replaceConfirmed {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            AppLogger.fs.info("move \(source.lastPathComponent) -> \(destination.lastPathComponent)")
        } catch let nsError as NSError {
            throw map(nsError, path: destination.path)
        }
    }

    func deleteItem(at url: URL) async throws {
        try validateInScope(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileSystemError.notFound(url.path)
        }
        do {
            try FileManager.default.removeItem(at: url)
            AppLogger.fs.info("delete \(url.lastPathComponent)")
        } catch let nsError as NSError {
            throw map(nsError, path: url.path)
        }
    }

    func renameItem(at url: URL, to newName: String) async throws -> URL {
        try validateInScope(url)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw FileSystemError.invalidDestination("Invalid name")
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard destination != url else { return destination }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileSystemError.alreadyExists(destination.path)
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            AppLogger.fs.info("rename \(url.lastPathComponent) -> \(trimmed)")
            return destination
        } catch let nsError as NSError {
            throw map(nsError, path: url.path)
        }
    }

    func compressItems(at urls: [URL], into archiveURL: URL) async throws {
        try validateInScope(archiveURL)
        for url in urls { try validateInScope(url) }
        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw FileSystemError.alreadyExists(archiveURL.path)
        }
        do {
            try ZipArchive.write(entries: urls, to: archiveURL)
            AppLogger.fs.info("compress \(urls.count) items -> \(archiveURL.lastPathComponent)")
        } catch {
            throw FileSystemError.archiveError(error.localizedDescription)
        }
    }

    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) async throws {
        try validateInScope(archiveURL)
        try validateInScope(destinationDirectory)
        do {
            try ZipArchive.extract(archiveURL: archiveURL, to: destinationDirectory)
            AppLogger.fs.info("extract \(archiveURL.lastPathComponent)")
        } catch {
            throw FileSystemError.archiveError(error.localizedDescription)
        }
    }

    func replaceItem(at target: URL, with source: URL) async throws {
        try validateInScope(target)
        try validateInScope(source)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw FileSystemError.notFound(target.path)
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FileSystemError.notFound(source.path)
        }
        let writable = FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
        guard writable else {
            throw FileSystemError.permissionDenied(target.path)
        }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
            AppLogger.fs.info("replace \(target.lastPathComponent)")
        } catch {
            // Fallback: explicit remove + copy, still guarded.
            try FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            AppLogger.fs.info("replace(fallback) \(target.lastPathComponent)")
        }
    }

    private func map(_ nsError: NSError, path: String) -> FileSystemError {
        guard nsError.domain == NSCocoaErrorDomain else {
            return .underlying(nsError.localizedDescription)
        }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .notFound(path)
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .permissionDenied(path)
        case NSFileWriteFileExistsError:
            return .alreadyExists(path)
        default:
            return .underlying(nsError.localizedDescription)
        }
    }
}
