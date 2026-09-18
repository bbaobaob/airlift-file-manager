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
    /// The capability each action needs from the filesystem backend.
    static func requiredCapability(_ action: FileContextAction) -> FileSystemCapabilities {
        switch action {
        case .open: return [.browse]
        case .copy: return [.copy]
        case .move: return [.move]
        case .rename: return [.rename]
        case .compress: return [.compress]
        case .extract: return [.extract]
        case .share: return [.share]
        case .replace: return [.write]
        case .duplicate: return [.copy]
        case .delete: return [.delete]
        case .getInfo: return [.readFile]
        }
    }

    /// Actions valid for this item on a backend with `capabilities`.
    /// Unsupported actions are simply not offered, per the product rule:
    /// never show a dead button.
    static func actions(for item: FileItem,
                        capabilities: FileSystemCapabilities = .fullSandbox) -> [FileContextAction] {
        var actions: [FileContextAction] = []
        if capabilities.contains(.browse) { actions.append(.open) }
        if capabilities.contains(.copy) { actions.append(.copy) }
        if capabilities.contains(.move) { actions.append(.move) }
        if capabilities.contains(.rename) { actions.append(.rename) }
        if capabilities.contains(.compress) { actions.append(.compress) }
        if capabilities.contains(.extract), item.url.pathExtension.lowercased() == "zip" {
            actions.append(.extract)
        }
        if capabilities.contains(.share) { actions.append(.share) }
        if capabilities.contains(.write) { actions.append(.replace) }
        if capabilities.contains(.copy), !item.isDirectory {
            actions.append(.duplicate)
        }
        if capabilities.contains(.readFile) { actions.append(.getInfo) }
        if capabilities.contains(.delete) { actions.append(.delete) }
        return actions
    }

    @ViewBuilder
    static func menu(for item: FileItem,
                     capabilities: FileSystemCapabilities = .fullSandbox,
                     onAction: @escaping (FileContextAction) -> Void) -> some View {
        ForEach(actions(for: item, capabilities: capabilities), id: \.rawValue) { action in
            Button(role: action == .delete ? .destructive : nil) {
                onAction(action)
            } label: {
                Label(action.rawValue, systemImage: action.systemImage)
            }
        }
    }
}
