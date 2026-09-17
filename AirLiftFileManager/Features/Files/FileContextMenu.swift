import SwiftUI

/// Context menu actions available for a single item. Contents adapt to the item kind.
enum FileContextAction: String, CaseIterable {
    case open = "Open"
    case copy = "Copy"
    case move = "Move"
    case rename = "Rename"
    case compress = "Compress"
    case extract = "Extract"
    case share = "Share"
    case replace = "Replace"
    case duplicate = "Duplicate"
    case delete = "Delete"
    case getInfo = "Get Info"

    var systemImage: String {
        switch self {
        case .open: return "doc.text"
        case .copy: return "doc.on.doc"
        case .move: return "folder.badge.plus"
        case .rename: return "pencil"
        case .compress: return "doc.zipper"
        case .extract: return "archivebox"
        case .share: return "square.and.arrow.up"
        case .replace: return "arrow.2.squarepath"
        case .duplicate: return "plus.square.on.square"
        case .delete: return "trash"
        case .getInfo: return "info.circle"
        }
    }
}

enum FileContextMenu {
    /// Actions valid for this item. Unsupported actions are simply not offered,
    /// per the product rule: never show a dead button.
    static func actions(for item: FileItem) -> [FileContextAction] {
        var actions: [FileContextAction] = []
        actions.append(.open)
        actions.append(.copy)
        actions.append(.move)
        actions.append(.rename)
        actions.append(.compress)
        if item.url.pathExtension.lowercased() == "zip" {
            actions.append(.extract)
        }
        actions.append(.share)
        actions.append(.replace)
        if !item.isDirectory {
            actions.append(.duplicate)
        }
        actions.append(.getInfo)
        actions.append(.delete)
        return actions
    }

    @ViewBuilder
    static func menu(for item: FileItem,
                     onAction: @escaping (FileContextAction) -> Void) -> some View {
        ForEach(actions(for: item), id: \.rawValue) { action in
            Button(role: action == .delete ? .destructive : nil) {
                onAction(action)
            } label: {
                Label(action.rawValue, systemImage: action.systemImage)
            }
        }
    }
}
