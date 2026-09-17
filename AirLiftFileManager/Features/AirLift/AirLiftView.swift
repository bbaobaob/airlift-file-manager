import SwiftUI
import UniformTypeIdentifiers

struct AirLiftView: View {
    @EnvironmentObject private var activation: ActivationManager
    @StateObject private var model = AirLiftViewModel()
    @State private var showingLogs = false

    var body: some View {
        NavigationStack {
            List {
            statusSection
            actionSection
            LocalDevVPNSection(state: model.tunnelState,
                               summary: model.tunnelSummary,
                               background: model.tunnelBackground,
                               isProbing: model.isProbingTunnel,
                               onRefresh: { Task { await model.probeTunnel() } })
            lockdownSection
            pairingSection
            capabilitiesSection
                scopeSection
                versionSection
            }
            .navigationTitle("AirLift")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLogs = true
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .accessibilityLabel("Technical logs")
                }
            }
            .sheet(isPresented: $showingLogs) {
                NavigationStack { AirLiftLogView() }
            }
            .fileImporter(isPresented: $model.showPairingImporter,
                          allowedContentTypes: [.propertyList, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await model.importPairing(from: url) }
                }
            }
            .task {
                model.refreshAccessReports()
                await model.probeTunnel()
            }
            .refreshable {
                model.refreshAccessReports()
                await model.probeTunnel()
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: AirLiftAdapter.icon(for: activation.state))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(AirLiftAdapter.color(for: activation.state))
                    .frame(width: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(activation.state.rawValue)
                        .font(.headline)
                    Text(activation.lastMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let verified = activation.lastVerifiedAt {
                        Text("Last verified: \(Formatters.date(verified))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

            if activation.isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }

            if let guidance = AirLiftAdapter.guidance(for: activation.state) {
                Label(guidance, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connection Status")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await activation.activate() }
            } label: {
                Label(activation.state == .notActivated ? "Activate AirLift" : "Retry Activation",
                      systemImage: "bolt.horizontal.circle")
            }
            .disabled(activation.isBusy)

            Button(role: .destructive) {
                activation.reset()
            } label: {
                Label("Reset Activation Data", systemImage: "arrow.counterclockwise")
            }
            .disabled(activation.isBusy)

            Button {
                Task { await activation.verifyOnLaunch() }
            } label: {
                Label("Verify Status Now", systemImage: "seal")
            }
            .disabled(activation.isBusy)
        } footer: {
            Text("Activation state is always re-verified against the real environment on launch. A stored flag is never treated as proof that AirLift is active.")
        }
    }

    private var lockdownSection: some View {
        Section {
            HStack {
                Image(systemName: model.lockdownResult?.reachable == true ? "lock.open.circle.fill" : "lock.circle")
                    .foregroundStyle(model.lockdownResult?.reachable == true ? Color.green : Color.secondary)
                Text(lockdownTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.isProbingLockdown {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.probeLockdown() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Probe lockdown")
                }
            }
            Text(lockdownDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Lockdown (on-device via tunnel)")
        } footer: {
            Text("Real lockdown plist exchange (QueryType/GetValue) over 10.7.0.1:62078 — the transport StikPair-class tools use and the on-device hop of the AirLift chain.")
        }
    }

    private var lockdownTitle: String {
        if model.isProbingLockdown { return "Probing…" }
        guard let result = model.lockdownResult else { return "Not probed" }
        return result.reachable ? "Lockdown reached" : "Lockdown unreachable"
    }

    private var lockdownDetail: String {
        guard let result = model.lockdownResult else {
            return "Connect LocalDevVPN, then probe. A successful exchange shows live device facts below."
        }
        guard result.reachable else {
            return result.error ?? "Connection failed."
        }
        var lines = ["QueryType: \(result.queryType ?? "?")"]
        if let v = result.productVersion { lines.append("iOS \(v)") }
        if let p = result.productType { lines.append("\(p)") }
        return lines.joined(separator: " · ")
    }

    private var pairingSection: some View {
        Section {
            Text(model.pairingStatus)
                .font(.footnote)
            Button {
                model.showPairingImporter = true
            } label: {
                Label(PairingRecordService.hasStoredPairing()
                      ? "Replace Pairing File" : "Import Pairing File",
                      systemImage: "key.horizontal")
            }
            if PairingRecordService.hasStoredPairing() {
                Button(role: .destructive) {
                    PairingRecordService.removePairing()
                    model.pairingStatus = "Pairing record removed."
                } label: {
                    Label("Remove Pairing Record", systemImage: "key.slash")
                }
            }
        } header: {
            Text("Pairing (StikPair-style, on-device)")
        } footer: {
            Text("Pair on-device with StikPair (Developer Mode → Pair with StikPair on iOS 27), export the pairing file, then import it here. The record enables trusted lockdown services (e.g. com.apple.afc) in a later build.")
        }
    }

    private var capabilitiesSection: some View {
        Section {
            capabilityRow("In-app activation",
                          model.capabilities.inAppActivationSupported ? "Supported" : "Not possible",
                          ok: model.capabilities.inAppActivationSupported)
            capabilityRow("LocalDevVPN integration",
                          model.capabilities.localDevVPNReferenced ? "Available" : "Not part of AirLift",
                          ok: model.capabilities.localDevVPNReferenced)
            capabilityRow("Read model", model.capabilities.readModel, ok: true)
            ForEach(model.capabilities.requiredHostComponents, id: \.self) { component in
                Label(component, systemImage: "desktopcomputer")
                    .font(.subheadline)
            }
        } header: {
            Text("AirLift Capabilities")
        } footer: {
            Text("Facts verified from the upstream repository: \(AppConstants.AirLift.repositoryURL)")
        }
    }

    private var scopeSection: some View {
        Section {
            ForEach(model.accessReports) { report in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(report.path)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Text(report.level.rawValue)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(badgeColor(report.level).opacity(0.18),
                                        in: Capsule())
                            .foregroundStyle(badgeColor(report.level))
                    }
                    Text(report.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Verified Write Scope (access from this device)")
        } footer: {
            Text("Each row reflects a real probe performed by this app on this device. AirLift can reach these paths only from the paired Mac.")
        }
    }

    private var versionSection: some View {
        Section("Version Info") {
            LabeledRow(label: "App", value: AppConstants.appName)
            LabeledRow(label: "App version",
                       value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
            LabeledRow(label: "AirLift tested builds",
                       value: model.capabilities.testedBuilds.joined(separator: ", "))
            LabeledRow(label: "Exploit host", value: AppConstants.AirLift.executionHost)
        }
    }

    private func capabilityRow(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(ok ? .green : .orange)
                .font(.subheadline.weight(.medium))
        }
    }

    private func badgeColor(_ level: AccessLevel) -> Color {
        switch level {
        case .accessible: return .green
        case .readOnly: return .blue
        case .restricted: return .orange
        case .unsupported: return .gray
        case .notFound: return .gray
        case .requiresExternalComponent: return .purple
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    AirLiftView()
}
