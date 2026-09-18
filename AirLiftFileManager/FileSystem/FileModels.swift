import Foundation

/// A single browsable item. `path` is the identity of the item.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let posixPermissions: Int?
    let isHidden: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var path: String { url.path }

    var typeLabel: String {
        if isDirectory { return "Folder" }
        return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased() + " File"
    }

    var fileKindIcon: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "zip": return "doc.zipper"
        case "png", "jpg", "jpeg", "heic", "gif": return "photo"
        case "mp4", "mov": return "film"
        case "mp3", "m4a", "wav": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "txt", "log", "md", "json", "plist": return "doc.plaintext"
        case "app", "ipa", "dylib": return "app.badge"
        default: return "doc"
        }
    }
}

enum SortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case dateModified = "Date Modified"
    case fileType = "File Type"
    var id: String { rawValue }
}

enum SortDirection {
    case ascending, descending

    var toggled: SortDirection {
        self == .ascending ? .descending : .ascending
    }
}

enum ViewMode: String, CaseIterable {
    case list = "List"
    case grid = "Grid"
}

/// Real access level of a probed directory. Never fabricated.
enum AccessLevel: String {
    case accessible = "Accessible"
    case readOnly = "Read-only"
    case restricted = "Restricted"
    case unsupported = "Unsupported"
    case notFound = "Not Found"
    case notTested = "Not tested"
    case connectionRequired = "Connection required"
    case requiresExternalComponent = "Requires External Component"

    var canBrowse: Bool { self == .accessible }
    var canRead: Bool { self == .accessible || self == .readOnly }
    var canWrite: Bool { self == .accessible }
}

struct DirectoryAccessReport: Identifiable {
    let path: String
    let level: AccessLevel
    let detail: String

    var id: String { path }
}

enum FileSystemError: LocalizedError, Equatable {
    case notFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case outsideScope(String)
    case unsupportedOperation(String)
    case replaceNotConfirmed(String)
    case invalidDestination(String)
    case archiveError(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "Not found: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .alreadyExists(let p): return "Already exists: \(p)"
        case .outsideScope(let p): return "Outside permitted scope: \(p)"
        case .unsupportedOperation(let m): return "Unsupported: \(m)"
        case .replaceNotConfirmed(let p): return "Replace requires confirmation: \(p)"
        case .invalidDestination(let m): return "Invalid destination: \(m)"
        case .archiveError(let m): return "Archive error: \(m)"
        case .underlying(let m): return m
        }
    }
}
