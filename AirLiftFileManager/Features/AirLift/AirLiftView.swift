import SwiftUI
import UniformTypeIdentifiers

/// Slim AirLift tab: launch gate status, tunnel, lockdown, diagnostics,
/// on-device self-test and the StikPair pairing guide. Removed: legacy
/// activation UI, static scope list and Version Info (covered by the Files
/// tab, Access Status and the self-test transcript).
struct AirLiftView: View {
    @EnvironmentObject private var launchGuard: AirLiftLaunchGuard
    @StateObject private var model = AirLiftViewModel()
    @State private var showingLogs = false
    @State private var showingSetup = false
    @State private var showingAccessStatus = false
    @State private var showPairingImporter = false
    @State private var showInAppPairing = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                SelfTestView(guardVM: launchGuard)
                stikPairSection
                LocalDevVPNSection(state: model.tunnelState,
                                   summary: model.tunnelSummary,
                                   background: model.tunnelBackground,
                                   isProbing: model.isProbingTunnel,
                                   onRefresh: { Task { await model.probeTunnel() } })
                lockdownSection
                accessStatusSection
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
            .sheet(isPresented: $showInAppPairing) {
                InAppPairingView(model: InAppPairingViewModel(
                    pairingStore: launchGuard.pairingStore)) {
                        Task { await launchGuard.recheckConnection() }
                    }
            }
            .navigationDestination(isPresented: $showingAccessStatus) {
                AccessStatusView(guardVM: launchGuard)
            }
            .fileImporter(isPresented: $showPairingImporter,
                          allowedContentTypes: PairingFileSupport.supportedContentTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        await launchGuard.importPairing(from: url)
                        await launchGuard.recheckConnection()
                    }
                case .failure(let error):
                    launchGuard.pairingStatusMessage =
                        "Picker error: \(error.localizedDescription)."
                    AppLogger.pairing.error(
                        "Document picker failed: \(error.localizedDescription)",
                        event: "pairing.import")
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
            Text("AirLift operates only with LocalDevVPN Connected and a valid Pairing File. Import or a tunnel alone is never treated as proof that AirLift is active.")
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

    /// In-app pairing entry (the real on-device ceremony; no separate app).
    private var stikPairSection: some View {
        Section {
            Button {
                showInAppPairing = true
            } label: {
                Label("Pair This iPhone Here", systemImage: "key.horizontal.fill")
            }
            Button {
                showPairingImporter = true
            } label: {
                Label("Import Pairing File", systemImage: "key.horizontal")
            }
            .font(.footnote)
            Text(launchGuard.pairingStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Pairing")
        } footer: {
            Text("Pairing runs inside this app (advertise, PIN, SRP). Import stays for records obtained elsewhere.")
        }
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
            Button("Access Status & Diagnostics") { showingAccessStatus = true }
                .font(.footnote.weight(.medium))
        } header: {
            Text("Access Status (live probes)")
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
        }
    }

    private var lockdownTitle: String {
        if model.isProbingLockdown { return "Probing…" }
        guard let result = model.lockdownResult else { return "Not probed" }
        return result.reachable ? "Lockdown reached" : "Lockdown unreachable"
    }

    private var lockdownDetail: String {
        guard let result = model.lockdownResult else {
            return "Connect LocalDevVPN, then probe."
        }
        guard result.reachable else {
            return result.error ?? "Connection failed."
        }
        var lines = ["QueryType: \(result.queryType ?? "?")"]
        if let v = result.productVersion { lines.append("iOS \(v)") }
        if let p = result.productType { lines.append("\(p)") }
        return lines.joined(separator: " · ")
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
