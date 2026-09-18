import Foundation

/// Books sync state over an AFC-shaped backend. Direct port of the
/// device_helper.m Books logic (tracked paths, snapshot/restore, absent
/// checks) that produces the exact "dọn books" transcript:
///
///   books[Books/Sync/Books.plist] = absent
///   ...
///   CLEAN
///   BOOKS DONE ✓
///
/// Safety rules (same as upstream Finish/RestoreBooksState):
/// - Only generated/staged paths are ever deleted.
/// - Tracked files are never deleted blindly: present ones are snapshotted
///   first and restored byte-for-byte; files absent in the snapshot are
///   removed only to undo our own staging.
protocol BooksFileAccess: Sendable {
    func exists(_ path: String) async -> Bool
    func read(_ path: String) async throws -> Data
    func write(_ path: String, data: Data) async throws
    func remove(_ path: String) async throws
    func makeDirectory(path: String) async throws
    func isDirectory(_ path: String) async -> Bool
}

/// Exact tracked paths from device_helper.m (relative to the Books AFC root).
enum TrackedBooksPaths {
    static let files = [
        "Books/Books.plist",
        "Books/Sync/Books.plist",
        "Books/Sync/Upload.plist",
        "Books/Sync/Database/OutstandingAssets_4.sqlite",
        "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
        "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
    ]
    static let directories = [
        "Books",
        "Books/Sync",
        "Books/Sync/Database",
    ]

    /// Generated staging name prefixes (airlift_target.h) — only these trees
    /// may be deleted wholesale.
    static let generatedPrefixes = [
        "airlift-src-",
        "airlift-link-",
        "airlift-recovered-",
    ]

    static func isGenerated(_ path: String) -> Bool {
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        return generatedPrefixes.contains { leaf.hasPrefix($0) }
    }
}

struct BooksState {
    enum CleanError: Error, Equatable {
        case snapshotFailed(String)
        case restoreFailed([String])
        case stillPresent([String])
    }

    struct CleanReport: Equatable {
        /// Per-file absent/present lines, in tracked order (video format).
        let lines: [String]
        /// All staged generated paths are gone.
        let generatedAbsent: Bool
        /// Snapshot restore produced no failures.
        let restored: Bool
        let failures: [String]

        /// CLEAN iff nothing failed and staged trees are gone. Preimage
        /// files restored from snapshot do NOT block CLEAN (upstream
        /// Finish checks the same: generated absent + books restored).
        var isClean: Bool { failures.isEmpty && generatedAbsent }
    }

    let access: any BooksFileAccess
    let log: (String) -> Void

    init(access: any BooksFileAccess,
         log: @escaping (String) -> Void = { line in
             AppLogger.airLift.info(line, event: "books")
         }) {
        self.access = access
        self.log = log
    }

    // MARK: - Snapshot (present tracked files only)

    /// Reads every present tracked file into memory. Never throws: missing
    /// files are simply absent from the snapshot.
    func snapshot() async -> [String: Data] {
        var out: [String: Data] = [:]
        for path in TrackedBooksPaths.files {
            if await access.exists(path),
               let data = try? await access.read(path) {
                out[path] = data
            }
        }
        if !out.isEmpty {
            emit("Preserving \(out.count) existing Books sync artifact\(out.count == 1 ? "" : "s").")
        }
        return out
    }

    // MARK: - Absent check (the video's exact lines)

    /// Logs `books[<path>] = absent|present` per tracked file, in order.
    /// Returns true only when every tracked file is absent.
    func verifyAbsent() async -> Bool {
        var allAbsent = true
        for path in TrackedBooksPaths.files {
            let present = await access.exists(path)
            emit("books[\(path)] = \(present ? "present" : "absent")")
            if present { allAbsent = false }
        }
        return allAbsent
    }

    // MARK: - Cleanup

    /// Removes caller-staged generated paths (never anything else).
    /// Returns paths that could not be removed.
    func removeGenerated(_ paths: [String]) async -> [String] {
        var failures: [String] = []
        for path in paths {
            guard TrackedBooksPaths.isGenerated(path) else { continue }
            do {
                try await removeTree(path)
                if await access.exists(path) {
                    failures.append(path)
                }
            } catch {
                failures.append(path)
            }
        }
        return failures
    }

    private func removeTree(_ path: String) async throws {
        // Directories cannot be listed through this protocol; the generated
        // trees we stage have known fixed shapes (archive tree), so removal
        // is attempted depth-first best-effort: exact path first, then the
        // known children the stager created.
        try? await access.remove(path)
        if await access.exists(path) {
            for child in await knownChildren(of: path) {
                try await removeTree(child)
            }
            try? await access.remove(path)
        }
    }

    /// Children the stager creates under a generated source root. The fixed
    /// archive layout (p0/p1/p2/link, payload, per-target dirs) is walked
    /// from the link/payload names recorded at stage time via `extra`.
    func knownChildren(of path: String, extra: [String] = []) -> [String] {
        var out = ["\(path)/p0/p1/p2/link", "\(path)/p0/p1/p2",
                   "\(path)/p0/p1", "\(path)/p0", "\(path)/payload"]
        out.append(contentsOf: extra.map { "\(path)/\($0)" })
        return out
    }

    /// Restores tracked files from a snapshot: present-in-snapshot files are
    /// rewritten byte-for-byte (creating parents); files absent in the
    /// snapshot are removed (they can only be our staging leftovers —
    /// anything else would have been snapshotted).
    /// Returns paths that could not be restored.
    func restore(snapshot: [String: Data]) async -> [String] {
        var failures: [String] = []
        for path in TrackedBooksPaths.files {
            if let data = snapshot[path] {
                do {
                    try await ensureParents(of: path)
                    try await access.write(path, data: data)
                    let back = try? await access.read(path: path)
                    if back != data {
                        failures.append(path)
                    }
                } catch {
                    failures.append(path)
                }
            } else {
                // Absent in preimage: remove only if it exists now.
                if await access.exists(path) {
                    try? await access.remove(path)
                    if await access.exists(path) {
                        failures.append(path)
                    }
                }
            }
        }
        return failures
    }

    private func ensureParents(of path: String) async throws {
        var components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        components.removeLast()
        var cursor = ""
        for component in components {
            cursor = cursor.isEmpty ? component : "\(cursor)/\(component)"
            if !(await access.exists(cursor)) {
                try await access.makeDirectory(path: cursor)
            } else if !(await access.isDirectory(cursor)) {
                throw CleanError.snapshotFailed("not a directory: \(cursor)")
            }
        }
    }

    // MARK: - Full "Dọn Books" run

    /// Snapshot → remove staged → restore preimage → per-file transcript.
    /// Emits the exact transcript from the reference run, ending with
    /// CLEAN / BOOKS DONE ✓ only when staged trees are gone and the
    /// restore verified. Files restored from the snapshot legitimately
    /// show `present` — that is the preimage, not dirt.
    func cleanBooks(stagedPaths: [String] = []) async -> CleanReport {
        let preimage = await snapshot()
        var failures = await removeGenerated(stagedPaths)
        var generatedAbsent = true
        for path in stagedPaths where TrackedBooksPaths.isGenerated(path) {
            if await access.exists(path) {
                generatedAbsent = false
                if !failures.contains(path) { failures.append(path) }
            }
        }
        let restoreFailures = await restore(snapshot: preimage)
        failures.append(contentsOf: restoreFailures)

        var lines: [String] = []
        for path in TrackedBooksPaths.files {
            let present = await access.exists(path)
            let line = "books[\(path)] = \(present ? "present" : "absent")"
            lines.append(line)
            emit(line)
        }

        let report = CleanReport(lines: lines, generatedAbsent: generatedAbsent,
                                 restored: restoreFailures.isEmpty, failures: failures)
        if report.isClean {
            emit("CLEAN")
            emit("BOOKS DONE ✓")
        } else {
            emit("CLEAN FAILED: \(failures.joined(separator: ", "))")
        }
        return report
    }

    private func emit(_ line: String) {
        AppLogger.airLift.info(line, event: "books")
        log(line)
    }
}

/// In-memory backend for tests (and dry runs).
final class InMemoryBooksAccess: BooksFileAccess, @unchecked Sendable {
    private struct Node {
        var isDirectory: Bool
        var data: Data
    }

    private var files: [String: Node] = [:]

    init(seed: [String: Data] = [:]) {
        for (path, data) in seed {
            files[path] = Node(isDirectory: false, data: data)
        }
    }

    func seedDirectory(_ path: String) {
        files[path] = Node(isDirectory: true, data: Data())
    }

    func exists(_ path: String) async -> Bool {
        files[path] != nil
    }

    func read(_ path: String) async throws -> Data {
        guard let node = files[path], !node.isDirectory else {
            throw AFCClient.AFCError.deviceStatus(8)
        }
        return node.data
    }

    func write(_ path: String, data: Data) async throws {
        files[path] = Node(isDirectory: false, data: data)
    }

    func remove(_ path: String) async throws {
        files.removeValue(forKey: path)
        // Remove directory children too (recursive tree removal).
        for key in files.keys where key.hasPrefix(path + "/") {
            files.removeValue(forKey: key)
        }
    }

    func makeDirectory(_ path: String) async throws {
        files[path] = Node(isDirectory: true, data: Data())
    }

    func isDirectory(_ path: String) async -> Bool {
        files[path]?.isDirectory ?? false
    }
}
