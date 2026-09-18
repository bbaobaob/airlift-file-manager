import Foundation

/// AFC-backed BooksFileAccess for the real device path.
final class AFCBooksAccess: BooksFileAccess {
    private var client: AFCClient

    init(client: AFCClient) {
        self.client = client
    }

    func exists(_ path: String) async -> Bool {
        await client.exists(path: path)
    }

    func read(_ path: String) async throws -> Data {
        let fd = try await client.open(path: path, mode: .readOnly)
        do {
            let data = try await client.readAll(fd: fd)
            try? await client.close(fd: fd)
            return data
        } catch {
            try? await client.close(fd: fd)
            throw error
        }
    }

    func write(_ path: String, data: Data) async throws {
        let fd = try await client.open(path: path, mode: .writeOnly)
        do {
            try await client.write(fd: fd, data: data)
            try await client.close(fd: fd)
        } catch {
            try? await client.close(fd: fd)
            throw error
        }
    }

    func remove(_ path: String) async throws {
        try await client.remove(path: path)
    }

    func makeDirectory(path: String) async throws {
        // Best-effort parents first (EnsureDirectory semantics).
        var components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else {
            try await client.makeDirectory(path: path)
            return
        }
        components.removeLast()
        var cursor = ""
        for component in components {
            cursor = cursor.isEmpty ? component : "\(cursor)/\(component)"
            if !(await client.exists(path: cursor)) {
                try await client.makeDirectory(path: cursor)
            }
        }
        if !(await client.exists(path: path)) {
            try await client.makeDirectory(path: path)
        }
    }

    func isDirectory(_ path: String) async -> Bool {
        (try? await client.kindOf(path: path)) == "S_IFDIR"
    }
}

/// One exploit-write attempt (upstream `attempt`, adapted on-device).
/// Builds the archive + Books manifest, stages via the conduit service +
/// AFC, and verifies everything AFC can see. The AirTraffic sync trigger
/// (upstream `airtraffic_host`) is a separate seam — see AirTrafficTrigger.
struct BooksAttempt {
    enum AttemptError: Error, Equatable {
        case noConduitService([String])
        case stageFailed(String)
    }

    struct Staged: Equatable {
        let source: String
        let linkDestination: String
        let recovered: String
        let archiveBytes: Int
        let token: String
    }

    /// Pure, tested: identifiers + destinations for one attempt.
    /// Mirrors upstream link/payload/target identifier construction.
    static func plan(target: String, leaf: String, token: String,
                     airlockRoot: String = AirlockArchive.airlockRoot) -> (
        identifiers: [String], destinations: [String],
        source: String, linkDestination: String, recovered: String,
        linkIdentifier: String, payloadIdentifier: String, targetIdentifier: String
    ) {
        let source = "airlift-src-\(token)"
        let linkDestination = "airlift-link-\(token)"
        let recovered = "airlift-recovered-\(token)"
        let linkIdentifier = "../../\(source)/p0/p1/p2/link"
        let targetPath = (target as NSString).appendingPathComponent(leaf)
        let targetIdentifier = relativePath(of: targetPath, to: airlockRoot)
        let payloadIdentifier = "../../\(source)/payload"
        let identifiers = [linkIdentifier, payloadIdentifier, targetIdentifier]
        let destinations = [linkDestination, "\(linkDestination)/\(leaf)", recovered]
        return (identifiers, destinations, source, linkDestination, recovered,
                linkIdentifier, payloadIdentifier, targetIdentifier)
    }

    /// Port of posixpath.relpath (lexical: common prefix, then one ".."
    /// per remaining root component). Upstream feeds this straight into the
    /// Books manifest, `..` segments included.
    static func relativePath(of path: String, to root: String) -> String {
        let pathParts = path.split(separator: "/").map(String.init)
        let rootParts = root.split(separator: "/").map(String.init)
        var common = 0
        while common < min(pathParts.count, rootParts.count),
              pathParts[common] == rootParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: rootParts.count - common)
        let down = Array(pathParts[common...])
        let parts = ups + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// Upstream canary payload (airlift canary + build + nonce).
    static func canaryPayload(build: String, nonce: String) -> Data {
        Data("airlift canary\nbuild=\(build)\nnonce=\(nonce)\n".utf8)
    }
}

/// AirTraffic sync trigger seam. Upstream drives this with
/// AirTrafficHost.framework (SyncAllowed → HostInfo → SyncRequest →
/// ReadyForSync → MetadataSyncFinished → assets → AssetCompleted), which has
/// no on-device equivalent: the ATCFMessage wire framing lives inside the
/// private framework and no public implementation exists. The seam models
/// the sequence so a future trigger plugs in without touching staging,
/// cleanup or UI — and reports precisely what is missing instead of
/// pretending to sync.
protocol AirTrafficTriggering: Sendable {
    /// Runs the Books sync for the staged identifiers/destinations.
    /// Throws `AirTrafficTriggerError.unimplemented` until a real trigger exists.
    func syncBooks(identifiers: [String], destinations: [String]) async throws
}

enum AirTrafficTriggerError: Error, Equatable {
    /// The ONLY current outcome: precise reason, no fake sync.
    case unimplemented(reason: String)
}

struct UnimplementedAirTrafficTrigger: AirTrafficTriggering {
    func syncBooks(identifiers: [String], destinations: [String]) async throws {
        throw AirTrafficTriggerError.unimplemented(
            reason: "AirTraffic sync needs AirTrafficHost.framework (Mac-only): the " +
                "ATCFMessage wire framing is private with no public implementation. " +
                "Staged \(identifiers.count) asset(s); sync not attempted.")
    }
}
