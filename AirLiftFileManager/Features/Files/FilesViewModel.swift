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
    let operations: FileOperationManager
    let rootURL: URL
    let locationTitle: String

    init(service: FileSystemService,
         operations: FileOperationManager? = nil,
         rootURL: URL,
         locationTitle: String,
         viewMode: ViewMode = .list,
         showHidden: Bool = false,
         sortField: SortField = .name,
         sortAscending: Bool = true) {
        self.service = service
        self.operations = operations ?? FileOperationManager(service: service)
        self.rootURL = rootURL
        self.currentURL = rootURL
        self.locationTitle = locationTitle
        self.viewMode = viewMode
        self.showHidden = showHidden
        self.sortField = sortField
        self.sortAscending = sortAscending
    }

    var directoryTitle: String {
        currentURL == rootURL ? locationTitle : currentURL.lastPathComponent
    }

    var sortedItems: [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let less: Bool
            switch sortField {
            case .name:
                less = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                less = lhs.size < rhs.size
            case .dateModified:
                less = (lhs.modificationDate ?? .distantPast) < (rhs.modificationDate ?? .distantPast)
            case .fileType:
                less = lhs.typeLabel < rhs.typeLabel
            }
            return sortAscending ? less : !less
        }
    }

    // MARK: - Loading

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.listDirectory(at: currentURL, includeHidden: showHidden)
            errorMessage = nil
        } catch {
            items = []
            errorMessage = ErrorHandler.present(error, context: "listDirectory")
        }
    }

    func openDirectory(_ url: URL) async {
        currentURL = url
        await refresh()
    }

    func goUpOne() -> URL? {
        guard currentURL != rootURL else { return nil }
        let parent = currentURL.deletingLastPathComponent()
        return parent == rootURL.deletingLastPathComponent() ? nil : parent
    }

    // MARK: - Operations

    func createFolder(named name: String) async { await run { try await operations.createFolder(named: name, in: currentURL) } }
    func rename(item: URL, to newName: String) async { await run { _ = try await operations.rename(item: item, to: newName) } }
    func delete(urls: [URL]) async { await run { try await operations.delete(items: urls) }; selection.end() }
    func copySelected(_ urls: [URL], to directory: URL) async { await run { try await operations.copy(items: urls, to: directory) } }
    func moveSelected(_ urls: [URL], to directory: URL) async { await run { try await operations.move(items: urls, to: directory) }; selection.end() }
    func compressSelected(_ selectedItems: [FileItem]) async { await run { _ = try await operations.compress(items: selectedItems, in: currentURL) } }
    func extract(archive: URL) async { await run { _ = try await operations.extract(archive: archive) } }
    func duplicate(item: URL) async { await run { _ = try await operations.duplicate(item: item) } }
    func replace(target: URL, with source: URL) async { await run { try await operations.replace(target: target, with: source) } }

    private func run(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            await refresh()
        } catch {
            errorMessage = ErrorHandler.present(error, context: "operation")
        }
    }

    func importFile(from tempURL: URL) async {
        let staged = tempURL.lastPathComponent.count > 37
            ? String(tempURL.lastPathComponent.dropFirst(37))
            : tempURL.lastPathComponent
        let destination = currentURL.appendingPathComponent(staged)
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

    func toggleSelection(_ item: FileItem) { selection.toggle(item) }
    func selectAll() { selection.selectAll(sortedItems) }

    func setItemsForTesting(_ newItems: [FileItem]) { items = newItems }
}
