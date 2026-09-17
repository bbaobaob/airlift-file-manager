import SwiftUI

/// Maps activation state to presentation facts (icon, color, guidance).
enum AirLiftAdapter {
    static func icon(for state: AirLiftState) -> String {
        switch state {
        case .activated: return "checkmark.seal.fill"
        case .notActivated: return "circle.dashed"
        case .preparing, .connecting, .activating, .verifying: return "arrow.triangle.2.circlepath"
        case .failed: return "xmark.octagon.fill"
        case .disconnected: return "bolt.slash.fill"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    static func color(for state: AirLiftState) -> Color {
        switch state {
        case .activated: return .green
        case .notActivated: return .secondary
        case .preparing, .connecting, .activating, .verifying: return .blue
        case .failed: return .red
        case .disconnected: return .orange
        case .unsupported: return .gray
        }
    }

    static func guidance(for state: AirLiftState) -> String? {
        switch state {
        case .unsupported:
            return "Activation must happen from a paired Mac running airlift. This app can display scope and status, but cannot perform the exploit in-process."
        case .disconnected:
            return "The AirLift channel was reachable before but is not now. Reconnect the paired Mac and retry."
        case .failed:
            return "The last attempt failed. Review the message and technical log, then retry."
        case .activated:
            return nil
        default:
            return nil
        }
    }
}
