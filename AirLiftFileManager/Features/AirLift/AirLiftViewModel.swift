import Foundation

@MainActor
final class AirLiftViewModel: ObservableObject {
    let capabilities = AirLiftCapabilities.current

    @Published var accessReports: [DirectoryAccessReport] = []
    @Published var tunnelState: VPNState = .unreachable(reason: "Not probed yet.")
    @Published var isProbingTunnel = false
    @Published var lockdownResult: LockdownProbeResult?
    @Published var isProbingLockdown = false

    private let permission: PermissionService
    private let localDevVPN: LocalDevVPNService

    init(permission: PermissionService = PermissionService(),
         localDevVPN: LocalDevVPNService = LocalDevVPNService()) {
        self.permission = permission
        self.localDevVPN = localDevVPN
    }

    func refreshAccessReports() {
        accessReports = permission.probeAll()
    }

    /// Live tunnel probe — real TCP connect to 10.7.0.1:62078.
    func probeTunnel() async {
        guard !isProbingTunnel else { return }
        isProbingTunnel = true
        defer { isProbingTunnel = false }
        let reachable = await localDevVPN.probeTunnel()
        tunnelState = localDevVPN.evaluate(reachable: reachable)
        if reachable {
            await probeLockdown()
        }
    }

    /// Real lockdown QueryType/GetValue exchange over the tunnel.
    func probeLockdown() async {
        guard !isProbingLockdown else { return }
        isProbingLockdown = true
        defer { isProbingLockdown = false }
        lockdownResult = await LockdownClient.probeDevice()
    }

    var tunnelSummary: String {
        switch tunnelState {
        case .connected(let detail): return detail
        case .unreachable(let reason): return reason
        }
    }

    var tunnelBackground: String { localDevVPN.backgroundInfo }
}
