import Foundation

/// High-level file operations with safety rules:
/// - never overwrites without explicit confirmation
/// - refuses paths outside the service scope
/// - surfaces typed errors instead of crashing
@MainActor
final class FileOperationManager: ObservableObject {
    let service: FileSystemService

    init(service: FileSystemService) {
        self.service = service
    }

    func uniqueArchiveName(for items: [FileItem], in directory: URL) -> String {
        let base = items.count == 1 ? items[0].name : "Archive"
        var name = base + ".zip"
        var counter = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base) \(counter).zip"
            counter += 1
        }
        return name
    }

    func copy(items: [URL], to directory: URL) async throws {
        for item in items {
            let destination = directory.appendingPathComponent(item.lastPathComponent)
            try await service.copyItem(at: item, to: destination, replaceConfirmed: false)
        }
    }

    func move(items: [URL], to directory: URL) async throws {
        for item in items {
            let destination = directory.appendingPathComponent(item.lastPathComponent)
            try await service.moveItem(at: item, to: destination, replaceConfirmed: false)
        }
    }

    func delete(items: [URL]) async throws {
        for item in items {
            try await service.deleteItem(at: item)
        }
    }

    func rename(item: URL, to newName: String) async throws -> URL {
        try await service.renameItem(at: item, to: newName)
    }

    func createFolder(named name: String, in directory: URL) async throws {
        try await service.createDirectory(at: directory.appendingPathComponent(name))
    }

    func compress(items: [FileItem], in directory: URL) async throws -> URL {
        let name = uniqueArchiveName(for: items, in: directory)
        let archive = directory.appendingPathComponent(name)
        try await service.compressItems(at: items.map(\.url), into: archive)
        return archive
    }

    func extract(archive: URL) async throws -> URL {
        let target = archive.deletingPathExtension()
        var finalTarget = target
        var counter = 2
        while FileManager.default.fileExists(atPath: finalTarget.path) {
            finalTarget = URL(fileURLWithPath: target.path + " \(counter)")
            counter += 1
        }
        try await service.extractArchive(at: archive, to: finalTarget)
        return finalTarget
    }

    func duplicate(item: URL) async throws -> URL {
        let parent = item.deletingLastPathComponent()
        let baseName = item.deletingPathExtension().lastPathComponent
        let ext = item.pathExtension
        var candidate = baseName + " copy" + (ext.isEmpty ? "" : "." + ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path) {
            candidate = "\(baseName) copy \(counter)" + (ext.isEmpty ? "" : "." + ext)
            counter += 1
        }
        let destination = parent.appendingPathComponent(candidate)
        try await service.copyItem(at: item, to: destination, replaceConfirmed: false)
        return destination
    }

    /// Replace requires the caller to have obtained explicit user confirmation.
    func replace(target: URL, with source: URL) async throws {
        try await service.replaceItem(at: target, with: source)
    }
}
