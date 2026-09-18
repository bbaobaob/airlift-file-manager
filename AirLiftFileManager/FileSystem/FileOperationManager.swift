import Foundation

/// High-level file operations with safety rules and cancellable progress:
/// - never overwrites without explicit confirmation
/// - refuses paths outside the service scope
/// - checks a cancellation flag between items; UI can abort mid-operation
@MainActor
final class FileOperationManager: ObservableObject {
    let service: FileSystemService

    @Published private(set) var activeOperation: String?
    @Published private(set) var progressCompleted = 0
    @Published private(set) var progressTotal = 0
    @Published private(set) var isRunning = false
    private var cancelRequested = false

    init(service: FileSystemService) {
        self.service = service
    }

    func cancelCurrentOperation() {
        guard isRunning else { return }
        cancelRequested = true
    }

    private func begin(_ operation: String, total: Int) {
        activeOperation = operation
        progressTotal = total
        progressCompleted = 0
        isRunning = true
        cancelRequested = false
    }

    private func tick() throws {
        guard !cancelRequested else { throw FileSystemError.underlying("Operation cancelled by user") }
        progressCompleted += 1
    }

    private func end() {
        activeOperation = nil
        isRunning = false
        progressCompleted = 0
        progressTotal = 0
        cancelRequested = false
    }

    // MARK: - Operations

    func copy(items: [URL], to directory: URL) async throws {
        begin("Copying", total: items.count)
        defer { end() }
        for (index, item) in items.enumerated() {
            try checkCancelBefore(index: index)
            let destination = service.uniqueDestination(directory.appendingPathComponent(item.lastPathComponent))
            try await service.copyItem(at: item, to: destination, replaceConfirmed: false)
            try tick()
        }
    }

    func move(items: [URL], to directory: URL) async throws {
        begin("Moving", total: items.count)
        defer { end() }
        for (index, item) in items.enumerated() {
            try checkCancelBefore(index: index)
            let destination = service.uniqueDestination(directory.appendingPathComponent(item.lastPathComponent))
            try await service.moveItem(at: item, to: destination, replaceConfirmed: false)
            try tick()
        }
    }

    func delete(items: [URL]) async throws {
        begin("Deleting", total: items.count)
        defer { end() }
        for (index, item) in items.enumerated() {
            try checkCancelBefore(index: index)
            try await service.deleteItem(at: item)
            try tick()
        }
    }

    func rename(item: URL, to newName: String) async throws -> URL {
        begin("Renaming", total: 1)
        defer { end() }
        let result = try await service.renameItem(at: item, to: newName)
        try tick()
        return result
    }

    func createFolder(named name: String, in directory: URL) async throws {
        begin("Creating folder", total: 1)
        defer { end() }
        try await service.createDirectory(at: directory.appendingPathComponent(name))
        try tick()
    }

    func compress(items: [FileItem], in directory: URL) async throws -> URL {
        begin("Compressing", total: 1)
        defer { end() }
        let name = uniqueArchiveName(for: items, in: directory)
        let archive = directory.appendingPathComponent(name)
        try await service.compressItems(at: items.map(\.url), into: archive)
        try tick()
        return archive
    }

    func extract(archive: URL) async throws -> URL {
        begin("Extracting", total: 1)
        defer { end() }
        let target = archive.deletingPathExtension()
        var finalTarget = target
        var counter = 2
        while FileManager.default.fileExists(atPath: finalTarget.path) {
            finalTarget = URL(fileURLWithPath: target.path + " \(counter)")
            counter += 1
        }
        try await service.extractArchive(at: archive, to: finalTarget)
        try tick()
        return finalTarget
    }

    func duplicate(item: URL) async throws -> URL {
        begin("Duplicating", total: 1)
        defer { end() }
        let parent = item.deletingLastPathComponent()
        let destination = service.uniqueDestination(parent.appendingPathComponent(
            item.deletingPathExtension().lastPathComponent + " copy"
            + (item.pathExtension.isEmpty ? "" : "." + item.pathExtension)))
        try await service.copyItem(at: item, to: destination, replaceConfirmed: false)
        try tick()
        return destination
    }

    func replace(target: URL, with source: URL) async throws {
        begin("Replacing", total: 1)
        defer { end() }
        try await service.replaceItem(at: target, with: source)
        try tick()
    }

    private func checkCancelBefore(index: Int) throws {
        if cancelRequested { throw FileSystemError.underlying("Operation cancelled by user") }
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
}
