import SwiftUI
import UniformTypeIdentifiers

struct AirLiftView: View {
    @EnvironmentObject private var activation: ActivationManager
    @EnvironmentObject private var launchGuard: AirLiftLaunchGuard
    @StateObject private var model = AirLiftViewModel()
    @State private var showingLogs = false
    @State private var showingSetup = false
    @State private var showingAccessStatus = false

    var body: some View {
        NavigationStack {
            List {
            statusSection
            actionSection
            connectionSection
            LocalDevVPNSection(state: model.tunnelState,
                               summary: model.tunnelSummary,
                               background: model.tunnelBackground,
                               isProbing: model.isProbingTunnel,
                               onRefresh: { Task { await model.probeTunnel() } })
            lockdownSection
            accessStatusSection
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
                NavigationStack { LogViewerView() }
            }
            .sheet(isPresented: $showingSetup) {
                AirLiftSetupRequiredView(guardVM: launchGuard) { showingSetup = false }
            }
            .navigationDestination(isPresented: $showingAccessStatus) {
                AccessStatusView(guardVM: launchGuard)
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

            Button {
                showingSetup = true
            } label: {
                Label("Connection Setup", systemImage: "circle.and.line.horizontal")
            }

            Button {
                showingAccessStatus = true
            } label: {
                Label("Access Status & Diagnostics", systemImage: "stethoscope")
            }

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

    private var connectionSection: some View {
        Section {
            launchStatusRow(title: "LocalDevVPN",
                            value: launchGuard.vpnStatus.rawValue,
                            ok: launchGuard.vpnStatus == .connected)
            launchStatusRow(title: "Pairing File",
                            value: launchGuard.pairingStatus.rawValue,
                            ok: launchGuard.pairingStatus == .imported)
            launchStatusRow(title: "AirLift",
                            value: launchGuard.launchState.rawValue,
                            ok: launchGuard.launchState == .readyToStart
                                || launchGuard.launchState == .running)
            if let reason = launchGuard.lastFailureReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    Task { await launchGuard.startAirLift() }
                } label: {
                    Label(launchGuard.launchState == .failed ? "Retry Start AirLift" : "Start AirLift",
                          systemImage: "bolt.horizontal.circle.fill")
                }
                .disabled(!launchGuard.canStartAirLift
                          || launchGuard.isChecking
                          || launchGuard.launchState == .starting)
                if launchGuard.launchState == .starting {
                    Spacer()
                    ProgressView()
                }
            }
            Button("Recheck Connection") {
                Task { await launchGuard.recheckConnection() }
            }
            .disabled(launchGuard.isChecking)
            Button("AirLift Setup") { showingSetup = true }
                .font(.footnote.weight(.medium))
        } header: {
            Text("AirLift Launch")
        } footer: {
            Text("AirLift launches only through the guarded preflight: LocalDevVPN Connected + valid Pairing File + transport verified. Import or a tunnel is never treated as proof that AirLift is active.")
        }
    }

    private func launchStatusRow(title: String, value: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(ok ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private var accessStatusSection: some View {
        Section {
            ForEach(model.accessReports.prefix(4)) { report in
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
            Text("Full per-path list in Access Status & Diagnostics and the Files tab.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } header: {
            Text("Access Status (live probes)")
        } footer: {
            Text("Each row reflects a real probe performed by this app on this device. AirLift can reach these paths only from the paired Mac.")
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

    private func badgeColor(_ level: AccessLevel) -> Color {
        switch level {
        case .accessible: return .green
        case .readOnly: return .blue
        case .restricted: return .orange
        case .notFound, .notTested: return .gray
        case .connectionRequired: return .purple
        case .unsupported, .requiresExternalComponent: return .secondary
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
        .environmentObject(AirLiftLaunchGuard())
}
