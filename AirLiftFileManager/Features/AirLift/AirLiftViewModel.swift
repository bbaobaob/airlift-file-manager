import Foundation

@MainActor
final class AirLiftViewModel: ObservableObject {
    let localDevVPN = LocalDevVPNService()
    let capabilities = AirLiftCapabilities.current

    @Published var accessReports: [DirectoryAccessReport] = []

    private let permission: PermissionService

    init(permission: PermissionService = PermissionService()) {
        self.permission = permission
    }

    func refreshAccessReports() {
        accessReports = permission.probeAll()
    }
}
