import Foundation

enum FileSystemError: LocalizedError {
    case unsupportedOnDevice(String)
    case requiresMac(String)
    case pathTraversalBlocked
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedOnDevice(let m): return "UnsupportedOnDevice: \(m)"
        case .requiresMac(let m): return "Requires Mac: \(m)"
        case .pathTraversalBlocked: return "Blocked: path contains '..' (symlink escape protection)"
        case .underlying(let e): return e.localizedDescription
        }
    }
}

struct FileEntry: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date
}

protocol FileSystemService {
    func list(path: String) throws -> [FileEntry]
    func read(path: String) throws -> Data
    func write(path: String, data: Data) throws
    func delete(path: String) throws
    func makeDirectory(path: String) throws
}
