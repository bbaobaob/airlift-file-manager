import Foundation

/// What a filesystem backend can actually do. UI reads this to show/hide
/// actions instead of ever showing a dead button from an unsupported backend.
struct FileSystemCapabilities: OptionSet, Hashable {
    let rawValue: Int

    static let browse      = FileSystemCapabilities(rawValue: 1 << 0)
    static let readFile    = FileSystemCapabilities(rawValue: 1 << 1)
    static let write       = FileSystemCapabilities(rawValue: 1 << 2)
    static let delete      = FileSystemCapabilities(rawValue: 1 << 3)
    static let rename      = FileSystemCapabilities(rawValue: 1 << 4)
    static let copy        = FileSystemCapabilities(rawValue: 1 << 5)
    static let move        = FileSystemCapabilities(rawValue: 1 << 6)
    static let compress    = FileSystemCapabilities(rawValue: 1 << 7)
    static let extract     = FileSystemCapabilities(rawValue: 1 << 8)
    static let share       = FileSystemCapabilities(rawValue: 1 << 9)
    static let quickLook   = FileSystemCapabilities(rawValue: 1 << 10)
    static let importFiles = FileSystemCapabilities(rawValue: 1 << 11)
    static let getInfo     = FileSystemCapabilities(rawValue: 1 << 12)

    static let fullSandbox: FileSystemCapabilities = [
        .browse, .readFile, .write, .delete, .rename, .copy, .move,
        .compress, .extract, .share, .quickLook, .importFiles, .getInfo
    ]
    static let readOnly: FileSystemCapabilities = [.browse, .readFile, .share, .quickLook, .getInfo]
    static let none: FileSystemCapabilities = []
}

enum FileSystemBackendKind: String, Hashable {
    case sandbox = "Sandbox"
    case sandboxTarget = "Sandbox Path"   // a system path probed from the sandbox
    case airLift = "AirLift"
}

/// A browsable location with its real backend and real access status.
struct FilesystemLocation: Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
    let backend: FileSystemBackendKind
    var access: AccessLevel
    var detail: String
    let isAppSandbox: Bool
}
