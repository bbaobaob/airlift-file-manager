import Foundation

@MainActor
final class DirectoryHubViewModel: ObservableObject {
    @Published private(set) var locations: [FilesystemLocation] = []
    @Published private(set) var isProbing = false
    @Published private(set) var lastProbedAt: Date?

    /// Probe function injected for tests; production uses PermissionService.
    let probe: @Sendable (String) -> DirectoryAccessReport

    init(probe: @escaping @Sendable (String) -> DirectoryAccessReport = { path in
        PermissionService().probe(path: path)
    }) {
        self.probe = probe
    }

    /// Runs a real probe per location; results feed the UI truthfully.
    func refresh() async {
        isProbing = true
        defer { isProbing = false }
        AppLogger.files.info("Directory hub refresh started")
        var out: [FilesystemLocation] = []

        // Row 0: the app sandbox — always real and always accessible.
        let docsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        out.append(FilesystemLocation(
            id: "sandbox", title: "My Files", path: docsPath.path,
            backend: .sandbox, access: .accessible,
            detail: "This app's sandbox. Fully accessible.", isAppSandbox: true))

        // Rows: AirLift's verified write scope, probed from this sandbox.
        for path in PermissionService.probedPaths {
            let report = probe(path)
            AppLogger.files.info("Hub probe \(path): \(report.level.rawValue)")
            out.append(FilesystemLocation(
                id: path, title: path, path: path,
                backend: .sandboxTarget, access: report.level,
                detail: report.detail, isAppSandbox: false))
        }
        let accessible = out.filter { $0.access.canBrowse }.count
        AppLogger.files.info("Directory hub: \(locationsSummary(out)) (browsable=\(accessible))")
        locations = out
        lastProbedAt = Date()
    }

    var browsableCount: Int {
        locations.filter { $0.access.canBrowse }.count
    }

    private func locationsSummary(_ list: [FilesystemLocation]) -> String {
        var counts: [String: Int] = [:]
        for location in list { counts[location.access.rawValue, default: 0] += 1 }
        return counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
    }
}
