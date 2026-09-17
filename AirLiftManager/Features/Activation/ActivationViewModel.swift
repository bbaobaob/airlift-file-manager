import Foundation
import SwiftUI

@MainActor
final class ActivationViewModel: ObservableObject {
    @Published var manager = ActivationManager()
    @Published var jsonText: String = ""
    @Published var info: String = "Paste TetherResult JSON from your Mac run, then tap Verify."

    var state: ActivationState { manager.state }

    func verifyPasted() {
        guard let data = jsonText.data(using: .utf8), !jsonText.isEmpty else {
            manager.markUnsupported(reason: "Empty input. Requires Mac tether JSON.")
            info = "Empty input."
            return
        }
        do {
            let r = try manager.verify(data: data)
            info = "VerifiedViaTether: \(r.udid) / \(r.iosBuild)"
        } catch {
            info = error.localizedDescription
        }
    }

    func markTetherRequired() {
        manager.markTetherRequired()
        info = "TetherRequired: connect to Mac tooling to produce TetherResult JSON."
    }

    func reset() {
        manager.reset()
        info = "Reset to NotActivated."
    }
}
