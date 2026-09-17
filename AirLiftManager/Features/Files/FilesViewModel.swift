import Foundation

@MainActor
final class FilesViewModel: ObservableObject {
    enum SortKey { case name, date, size }
    enum Layout { case list, grid }

    @Published var entries: [FileEntry] = []
    @Published var currentPath: String = "/"
    @Published var sortKey: SortKey = .name
    @Published var layout: Layout = .list
    @Published var selection = Set<String>()
    @Published var errorMessage: String?

    private let service: FileSystemService = SandboxFileSystemService()

    func refresh() {
        do {
            var list = try service.list(path: currentPath)
            switch sortKey {
            case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .date: list.sort { $0.modified > $1.modified }
            case .size: list.sort { $0.size > $1.size }
            }
            entries = list
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            entries = []
        }
    }

    func enter(_ e: FileEntry) {
        guard e.isDirectory else { return }
        currentPath = e.path
        selection.removeAll()
        refresh()
    }

    func goUp() {
        if currentPath != "/" {
            currentPath = (currentPath as NSString).deletingLastPathComponent
            if currentPath.isEmpty { currentPath = "/" }
            refresh()
        }
    }

    func delete(_ e: FileEntry) {
        do { try service.delete(path: e.path); refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func mkdir(name: String) {
        do { try service.makeDirectory(path: currentPath == "/" ? "/" + name : currentPath + "/" + name); refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func zipSelection() throws -> URL {
        // ZIP via Foundation: coordinate reading + NSFileCoordinator not needed for sandbox demo;
        // use FileManager + simple archive via `zip` is out of scope on-device.
        // Minimal honest implementation: throw UnsupportedOnDevice with guidance, OR
        // create a .zip manifest placeholder? We implement real ZIP only if Compression framework path exists.
        // For scaffold honesty: report unsupported until Mac runner verifies Compression availability.
        throw FileSystemError.unsupportedOnDevice("ZIP export not yet wired in scaffold; use Files app share. Requires Mac runner verification.")
    }
}
