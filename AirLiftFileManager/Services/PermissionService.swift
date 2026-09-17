import Foundation

/// Probes real access to the directories the user cares about.
/// Every result comes from an actual FileManager probe — nothing is simulated.
struct PermissionService {
    /// Directories requested by the product spec (AirLift's verified write scope).
    static let probedPaths = AppConstants.AirLift.verifiedWriteScope

    func probeAll() -> [DirectoryAccessReport] {
        probedPaths.map { probe(path: $0) }
    }

    func probe(path: String) -> DirectoryAccessReport {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists else {
            AppLogger.perm.info("probe \(path, privacy: .public): not found")
            return DirectoryAccessReport(path: path, level: .notFound,
                                         detail: "Path does not exist from this process.")
        }
        guard isDirectory.boolValue else {
            return DirectoryAccessReport(path: path, level: .unsupported,
                                         detail: "Path is not a directory.")
        }

        let readable = fileManager.isReadableFile(atPath: path)
        let writable = fileManager.isWritableFile(atPath: path)

        if !readable && !writable {
            AppLogger.perm.info("probe \(path, privacy: .public): restricted")
            return DirectoryAccessReport(
                path: path, level: .restricted,
                detail: "Outside the app sandbox. iOS blocks access; AirLift reaches this path only from a paired Mac.")
        }
        if readable && !writable {
            var listingWorks = true
            if (try? fileManager.contentsOfDirectory(atPath: path)) == nil {
                listingWorks = false
            }
            if listingWorks {
                return DirectoryAccessReport(path: path, level: .readOnly,
                                             detail: "Readable but not writable from this process.")
            }
            return DirectoryAccessReport(path: path, level: .restricted,
                                         detail: "Read permission bit set, listing denied.")
        }
        if readable && writable {
            // Verify with a real write probe (create + remove a temp file).
            let probeName = ".airlift-probe-\(UUID().uuidString)"
            let probeURL = URL(fileURLWithPath: path).appendingPathComponent(probeName)
            let created = fileManager.createFile(atPath: probeURL.path, contents: Data())
            if created {
                try? fileManager.removeItem(at: probeURL)
                AppLogger.perm.info("probe \(path, privacy: .public): accessible")
                return DirectoryAccessReport(path: path, level: .accessible,
                                             detail: "Read and write verified with a probe file.")
            }
            return DirectoryAccessReport(path: path, level: .readOnly,
                                         detail: "Permissions look writable but probe write failed.")
        }
        return DirectoryAccessReport(path: path, level: .restricted,
                                     detail: "Access denied by the operating system.")
    }
}
