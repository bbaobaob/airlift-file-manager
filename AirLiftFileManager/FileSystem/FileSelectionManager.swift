import Foundation

/// Selection-mode state. Pure logic, unit tested without UI.
@MainActor
final class FileSelectionManager: ObservableObject {
    @Published private(set) var selected: Set<URL> = []
    @Published var isActive: Bool = false

    var count: Int { selected.count }
    var isEmpty: Bool { selected.isEmpty }

    func begin() {
        isActive = true
        selected = []
    }

    func end() {
        isActive = false
        selected = []
    }

    func toggle(_ item: FileItem) {
        if selected.contains(item.url) {
            selected.remove(item.url)
        } else {
            selected.insert(item.url)
        }
    }

    func isSelected(_ item: FileItem) -> Bool {
        selected.contains(item.url)
    }

    /// Selects every valid item in the current directory. Items that failed to
    /// load are never included because only resolved FileItems reach this call.
    func selectAll(_ items: [FileItem]) {
        guard isActive else { return }
        selected.formUnion(items.map(\.url))
    }

    func deselectAll() {
        selected.removeAll()
    }

    func selectedItems(from items: [FileItem]) -> [FileItem] {
        items.filter { selected.contains($0.url) }
    }
}
