import SwiftUI
import UniformTypeIdentifiers

/// Full-screen setup flow: LocalDevVPN → pairing file → lockdown transport →
/// capabilities. Every step shows its REAL result. The user can leave the
/// flow and use the sandbox-only Files tab at any time.
struct ConnectionSetupView: View {
    @ObservedObject var gate: ConnectionGateViewModel
    let onDismiss: () -> Void

    @State private var showPairingImporter = false

    var body: some View {
        NavigationStack {
            List {
                introSection
                stepsSection
                pairingSection
                vpnHelpSection
                footerSection
            }
            .navigationTitle("Connection Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { onDismiss() }
                        .accessibilityLabel("Continue in sandbox-only mode")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run Checks") {
                        Task { await gate.runChecks() }
                    }
                    .disabled(gate.isBusy)
                }
            }
            .fileImporter(isPresented: $showPairingImporter,
                          allowedContentTypes: [.propertyList, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        await gate.importPairing(from: url)
                        await gate.runChecks()
                    }
                }
            }
            .task { await gate.runChecks() }
        }
    }

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(gate.statusSummary,
                      systemImage: gate.phase == .ready
                      ? "checkmark.seal.fill"
                      : (gate.phase == .failed ? "xmark.octagon.fill" : "dot.circle.and.cursorarrow"))
                    .font(.headline)
                Text("Checks run against the real environment. A TCP connect proves the tunnel only; a lockdown exchange proves transport only. Neither is treated as filesystem access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var stepsSection: some View {
        Section("Verification Steps") {
            ForEach(gate.steps) { step in
                HStack(alignment: .top, spacing: 12) {
                    stepIcon(step)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.subheadline.weight(.medium))
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if step.status == .running {
                        ProgressView()
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.title): \(step.status.rawValue)")
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ step: ConnectionCheckStep) -> some View {
        switch step.status {
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .waitingForUser:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        Section {
            // Pairing File
            Text(gate.pairingStatusMessage)
                .font(.footnote)
            Button {
                showPairingImporter = true
            } label: {
                Label(gate.pairingStore.hasRecord
                      ? "Replace Pairing File" : "Import Pairing File",
                      systemImage: "key.horizontal")
            }
            if gate.pairingStore.hasRecord {
                Button(role: .destructive) {
                    gate.removePairing()
                } label: {
                    Label("Remove Pairing Record", systemImage: "key.slash")
                }
            }
            if let lockdown = gate.lastLockdownResult, lockdown.reachable {
                LabeledRow(label: "Lockdown", value: "Reached (\(lockdown.queryType ?? "?"))")
                if let v = lockdown.productVersion {
                    LabeledRow(label: "Device iOS", value: v)
                }
            }
        } header: {
            Text("Pairing File")
        } footer: {
            Text("Pair on-device with StikPair (iOS 27 Developer Mode → Pair with StikPair), export the pairing plist, and import it here. It is stored in the Keychain — never in plain files — and its contents are never logged.")
        }
    }

    private var vpnHelpSection: some View {
        Section {
            ForEach(AppConstants.LocalDevVPN.relatedProjects, id: \.self) { project in
                Label(project, systemImage: "link")
                    .font(.caption2)
            }
        } header: {
            Text("If the tunnel is missing")
        } footer: {
            Text("Install LocalDevVPN (or SideStore StosVPN) and connect it. The tunnel maps 10.7.0.1 to this device's own services (lockdown 62078). Keep Wi-Fi enabled while the tunnel is active.")
        }
    }

    private var footerSection: some View {
        Section {
            Button {
                onDismiss()
            } label: {
                Label("Continue in Sandbox-Only Mode", systemImage: "folder")
            }
            Text("The Files tab always works on this app's real sandbox, with or without a connection. AirLift-dependent features stay locked until every check above passes — and out-of-sandbox writes additionally require the paired-Mac AirLift tool.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ConnectionSetupView(gate: ConnectionGateViewModel(), onDismiss: {})
}
