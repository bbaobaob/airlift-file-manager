import Foundation
import Combine

/// Top-level application state. Owns long-lived services and wires them together.
@MainActor
final class AppState: ObservableObject {
    let fileSystem: FileSystemService
    let operations: FileOperationManager
    let permission: PermissionService
    let activation: ActivationManager
    let persistence: PersistenceService
    let launchGuard: AirLiftLaunchGuard

    init(fileSystem: FileSystemService = SandboxFileSystemService(),
         persistence: PersistenceService = PersistenceService()) {
        self.persistence = persistence
        self.fileSystem = fileSystem
        self.operations = FileOperationManager(service: fileSystem)
        self.permission = PermissionService()
        let airLift = AirLiftService()
        self.activation = ActivationManager(
            probe: airLift,
            persistence: persistence
        )
        self.launchGuard = AirLiftLaunchGuard()
        AppLogger.app.info("AppState initialized")
    }

    /// Runs startup verification so persisted state is re-checked against reality.
    func performStartupVerification() async {
        await activation.verifyOnLaunch()
    }
}
