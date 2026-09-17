import Foundation

/// Real CRUD confined to the app sandbox Documents/ directory.
/// Blocks "../" to prevent symlink / path escape. No /var/mobile/* access.
final class SandboxFileSystemService: FileSystemService {
    private let fm = FileManager.default
    private var documentsURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func resolved(_ path: String) throws -> URL {
        if path.contains("..") { throw FileSystemError.pathTraversalBlocked }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return documentsURL }
        let url = documentsURL.appendingPathComponent(trimmed, isDirectory: false)
        // Containment check (symlink escape protection)
        let base = documentsURL.standardized.path
        let dest = url.standardized.path
        guard dest == base || dest.hasPrefix(base + "/") else {
            throw FileSystemError.pathTraversalBlocked
        }
        return url
    }

    func list(path: String) throws -> [FileEntry] {
        do {
            let url = try resolved(path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            guard isDir.boolValue else { return [] }
            let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return try items.map { u in
                let vals = try u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let rel = u.path.replacingOccurrences(of: documentsURL.path, with: "")
                return FileEntry(name: u.lastPathComponent, path: rel.isEmpty ? "/" : rel,
                                 isDirectory: vals.isDirectory ?? false,
                                 size: Int64(vals.fileSize ?? 0),
                                 modified: vals.contentModificationDate ?? Date())
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let e as FileSystemError { throw e }
        catch { throw FileSystemError.underlying(error) }
    }

    func read(path: String) throws -> Data {
        do { return try Data(contentsOf: resolved(path)) }
        catch let e as FileSystemError { throw e }
        catch { throw FileSystemError.underlying(error) }
    }

    func write(path: String, data: Data) throws {
        do { try data.write(to: resolved(path), options: .atomic) }
        catch let e as FileSystemError { throw e }
        catch { throw FileSystemError.underlying(error) }
    }

    func delete(path: String) throws {
        do { try fm.removeItem(at: resolved(path)) }
        catch let e as FileSystemError { throw e }
        catch { throw FileSystemError.underlying(error) }
    }

    func makeDirectory(path: String) throws {
        do { try fm.createDirectory(at: resolved(path), withIntermediateDirectories: true) }
        catch let e as FileSystemError { throw e }
        catch { throw FileSystemError.underlying(error) }
    }
}
