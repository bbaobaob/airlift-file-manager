import XCTest
@testable import AirLiftFileManager

@MainActor
final class SortingTests: XCTestCase {
    private func makeItem(_ name: String, size: Int64, date: Date, ext: String) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/sort/\(name).\(ext)"),
                 isDirectory: false, size: size,
                 modificationDate: date, creationDate: nil,
                 posixPermissions: 0o644, isHidden: false)
    }

    private func sorted(_ items: [FileItem], field: SortField, ascending: Bool) -> [FileItem] {
        let model = FilesViewModel(service: SandboxFileSystemService(),
                                   operations: FileOperationManager(
                                       service: SandboxFileSystemService()),
                                   sortField: field,
                                   sortAscending: ascending)
        // Inject preloaded items through the sortedItems path via reflection-free setup:
        // sortedItems sorts `items`; we use a small test seam instead.
        model.injectForTesting(items)
        return model.sortedItems
    }

    func testSortByName() {
        let base = Date(timeIntervalSince1970: 0)
        let items = [
            makeItem("c", size: 3, date: base, ext: "txt"),
            makeItem("a", size: 1, date: base, ext: "zip"),
            makeItem("b", size: 2, date: base, ext: "md"),
        ]
        XCTAssertEqual(sorted(items, field: .name, ascending: true).map(\.name),
                       ["a", "b", "c"])
        XCTAssertEqual(sorted(items, field: .name, ascending: false).map(\.name),
                       ["c", "b", "a"])
    }

    func testSortBySize() {
        let base = Date(timeIntervalSince1970: 0)
        let items = [
            makeItem("big", size: 900, date: base, ext: "bin"),
            makeItem("small", size: 2, date: base, ext: "bin"),
            makeItem("mid", size: 40, date: base, ext: "bin"),
        ]
        XCTAssertEqual(sorted(items, field: .size, ascending: true).map(\.name),
                       ["small", "mid", "big"])
        XCTAssertEqual(sorted(items, field: .size, ascending: false).map(\.name),
                       ["big", "mid", "small"])
    }

    func testSortByDate() {
        let now = Date()
        let items = [
            makeItem("old", size: 1, date: now.addingTimeInterval(-100), ext: "log"),
            makeItem("new", size: 1, date: now, ext: "log"),
            makeItem("mid", size: 1, date: now.addingTimeInterval(-50), ext: "log"),
        ]
        XCTAssertEqual(sorted(items, field: .dateModified, ascending: true).map(\.name),
                       ["old", "mid", "new"])
    }

    func testSortByFileType() {
        let base = Date(timeIntervalSince1970: 0)
        let items = [
            makeItem("z", size: 1, date: base, ext: "zip"),
            makeItem("p", size: 1, date: base, ext: "png"),
            makeItem("t", size: 1, date: base, ext: "txt"),
        ]
        XCTAssertEqual(sorted(items, field: .fileType, ascending: true).map(\.name),
                       ["p", "t", "z"]) // PNG, TXT, ZIP
    }

    func testDirectoriesAlwaysFirst() {
        let base = Date(timeIntervalSince1970: 0)
        let dir = FileItem(url: URL(fileURLWithPath: "/tmp/sort/folder"),
                           isDirectory: true, size: 0, modificationDate: base,
                           creationDate: nil, posixPermissions: 0o755, isHidden: false)
        let file = makeItem("aaa", size: 999_999, date: base, ext: "bin")
        let result = sorted([file, dir], field: .size, ascending: false)
        XCTAssertEqual(result.first?.isDirectory, true)
    }
}

@MainActor
extension FilesViewModel {
    /// Test seam: inject items without touching the filesystem.
    func injectForTesting(_ items: [FileItem]) {
        // items is private(set); use keypath-free approach by calling refresh-free setter.
        setItemsForTesting(items)
    }
}
