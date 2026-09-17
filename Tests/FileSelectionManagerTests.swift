import XCTest
@testable import AirLiftFileManager

@MainActor
final class FileSelectionManagerTests: XCTestCase {
    private func makeItem(_ name: String, isDirectory: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/sel/\(name)"),
                 isDirectory: isDirectory, size: 10,
                 modificationDate: Date(), creationDate: nil,
                 posixPermissions: 0o644, isHidden: false)
    }

    func testBeginEndResetsSelection() {
        let manager = FileSelectionManager()
        manager.begin()
        XCTAssertTrue(manager.isActive)
        manager.toggle(makeItem("a"))
        XCTAssertEqual(manager.count, 1)
        manager.end()
        XCTAssertFalse(manager.isActive)
        XCTAssertTrue(manager.isEmpty)
    }

    func testToggleSelectsAndDeselects() {
        let manager = FileSelectionManager()
        let item = makeItem("file.txt")
        manager.begin()
        manager.toggle(item)
        XCTAssertTrue(manager.isSelected(item))
        XCTAssertEqual(manager.count, 1)
        manager.toggle(item)
        XCTAssertFalse(manager.isSelected(item))
        XCTAssertEqual(manager.count, 0)
    }

    func testSelectAllSelectsEveryResolvedItem() {
        let manager = FileSelectionManager()
        let items = [makeItem("1"), makeItem("2", isDirectory: true), makeItem("3")]
        manager.begin()
        manager.selectAll(items)
        XCTAssertEqual(manager.count, 3)
        manager.deselectAll()
        XCTAssertEqual(manager.count, 0)
    }

    func testSelectAllIgnoredWhenInactive() {
        let manager = FileSelectionManager()
        manager.selectAll([makeItem("x")])
        XCTAssertEqual(manager.count, 0)
    }

    func testSelectedItemsFiltersCorrectly() {
        let manager = FileSelectionManager()
        let items = [makeItem("a"), makeItem("b"), makeItem("c")]
        manager.begin()
        manager.toggle(items[0])
        manager.toggle(items[2])
        let selected = manager.selectedItems(from: items)
        XCTAssertEqual(selected.map(\.name), ["a", "c"])
    }
}
