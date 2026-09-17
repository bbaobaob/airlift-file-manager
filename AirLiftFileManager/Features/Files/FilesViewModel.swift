import Foundation
import Combine

@MainActor
final class FilesViewModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var currentURL: URL
    @Published var errorMessage: String?
    @Published var viewMode: ViewMode
    @Published var showHidden: Bool
    @Published var sortField: SortField
    @Published var sortAscending: Bool

    let selection = FileSelectionManager()
    let service: FileSystemService
    private let operations: FileOperationManager

    var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var directoryTitle: String {
        currentURL == rootURL ? "Files" : currentURL.lastPathComponent
    }

    var sortedItems: [FileItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let result: Bool
            switch sortField {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                result = lhs.size < rhs.size
            case .dateModified:
                result = (lhs.modificationDate ?? .distantPast) < (rhs.modificationDate ?? .distantPast)
            case .fileType:
                result = lhs.typeLabel < rhs.typeLabel
            }
            return sortAscending ? result : !result
        }
        return sorted
    }

    init(service: FileSystemService,
         operations: FileOperationManager,
         viewMode: ViewMode = .list,
         showHidden: Bool = false,
         sortField: SortField = .name,
         sortAscending: Bool = true) {
        self.service = service
        self.operations = operations
        self.viewMode = viewMode
        self.showHidden = showHidden
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.currentURL = FileManager.default.urls(for: .documentDirectory,
                                                   in: .userDomainMask)[0]
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.listDirectory(at: currentURL, includeHidden: showHidden)
            errorMessage = nil
            AppLogger.files.debug("Loaded \(items.count) items in \(currentURL.lastPathComponent)")
        } catch {
            items = []
            errorMessage = ErrorHandler.present(error, context: "listDirectory")
        }
    }

    func openDirectory(_ url: URL) async {
        currentURL = url
        await refresh()
    }

    func goUp() async {
        guard currentURL != rootURL else { return }
        await openDirectory(currentURL.deletingLastPathComponent())
    }

    func goUpOne() -> URL? {
        guard currentURL != rootURL else { return nil }
        return currentURL.deletingLastPathComponent()
    }

    // MARK: - Operations

    func createFolder(named name: String) async {
        do {
            try await operations.createFolder(named: name, in: currentURL)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "createFolder")
        }
    }

    func rename(item: URL, to newName: String) async {
        do {
            _ = try await operations.rename(item: item, to: newName)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "rename")
        }
    }

    func delete(urls: [URL]) async {
        do {
            try await operations.delete(items: urls)
            selection.end()
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "delete")
        }
    }

    func copySelected(_ urls: [URL], to directory: URL) async {
        do {
            try await operations.copy(items: urls, to: directory)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "copy")
        }
    }

    func moveSelected(_ urls: [URL], to directory: URL) async {
        do {
            try await operations.move(items: urls, to: directory)
            selection.end()
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "move")
        }
    }

    func compressSelected(_ selectedItems: [FileItem]) async {
        do {
            _ = try await operations.compress(items: selectedItems, in: currentURL)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "compress")
        }
    }

    func extract(archive: URL) async {
        do {
            _ = try await operations.extract(archive: archive)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "extract")
        }
    }

    func duplicate(item: URL) async {
        do {
            _ = try await operations.duplicate(item: item)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "duplicate")
        }
    }

    func replace(target: URL, with source: URL) async {
        do {
            try await operations.replace(target: target, with: source)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "replace")
        }
    }

    /// Imports a file already staged in the app container (temp copy done by caller
    /// while the security scope was active).
    func importFile(from tempURL: URL) async {
        let destination = currentURL.appendingPathComponent(tempURL.lastPathComponent.dropFirst(37))
        if FileManager.default.fileExists(atPath: destination.path) {
            errorMessage = FileSystemError.replaceNotConfirmed(destination.path).localizedDescription
            return
        }
        do {
            try await service.copyItem(at: tempURL, to: destination, replaceConfirmed: false)
            try? FileManager.default.removeItem(at: tempURL)
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "importFile")
        }
    }

    func toggleSelection(_ item: FileItem) {
        selection.toggle(item)
    }

    func selectAll() {
        selection.selectAll(sortedItems)
    }

    /// Test seam: inject items without touching the filesystem.
    func setItemsForTesting(_ newItems: [FileItem]) {
        items = newItems
    }
}
