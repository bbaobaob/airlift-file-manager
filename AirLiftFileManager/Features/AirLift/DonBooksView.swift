import SwiftUI

/// "Dọn Books" — Books sync-state cleanup + exploit staging, all over the
/// real RSD/AFC chain. Every step logs exactly what happened:
///
/// - RSD service table (reveals conduit/ATC ports on THIS device)
/// - Dọn Books: snapshot → remove staged → restore preimage → per-file
///   `books[...] = absent` lines → CLEAN / BOOKS DONE ✓ (video format)
/// - Stage Archive (experimental): builds the exact Airlock archive +
///   Books.plist, streams the archive to `com.apple.streaming_zip_conduit`
///   when RSD advertises it, writes Books.plist, verifies what AFC can see.
///   The AirTraffic sync trigger is a separate pending seam (framing is
///   private); staging reports precisely where it stopped.
///
/// All actions require the launch guard (VPN + valid pairing), same as Start.
@MainActor
final class DonBooksViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [String] = []
    @Published var targetDirectory: String = "/var/mobile/Library/SpringBoard"
    private var runTask: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private func emit(_ line: String) {
        AppLogger.airLift.info(line, event: "books")
        lines.append(line)
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning {
            lines.append("Cancelled by user.")
            phase = .idle
        }
    }

    func clear() {
        guard !isRunning else { return }
        phase = .idle
        lines = []
    }

    // MARK: - Shared front half

    /// Gates + RSD establishment shared by every action. Returns the
    /// handshake (service table) for the caller to dial services.
    private func establish(chain: OnDeviceChain) async throws -> RSDClient.Handshake {
        guard let recordData = chain.pairingStore.load(),
              PairingRecordService.validate(recordData).isValid else {
            throw OnDeviceChain.ChainError.noPairingRecord
        }
        guard await chain.vpnProbe() else {
            throw OnDeviceChain.ChainError.tunnelDown
        }
        let establisher = RSDEstablisher(host: chain.host, discover: chain.discover,
                                         log: { [weak self] line in
                                             Task { @MainActor [weak self] in
                                                 self?.lines.append(line)
                                             }
                                         })
        return try await establisher.establish(recordData: recordData).handshake
    }

    private func afcAccess(chain: OnDeviceChain,
                           handshake: RSDClient.Handshake) async throws -> AFCBooksAccess {
        guard let afcPort = handshake.port(for: RSDClient.afcServiceName) else {
            throw OnDeviceChain.ChainError.stepFailed(
                step: "RSD services",
                reason: "no \(RSDClient.afcServiceName) (services: " +
                    "\(handshake.services.keys.sorted().joined(separator: ", ")))")
        }
        let stream = try await TCPStream(host: chain.host, port: afcPort, timeout: 10)
        var client = AFCClient(stream: stream, timeout: 10)
        try await client.checkin()
        return AFCBooksAccess(client: client)
    }

    // MARK: - Actions

    func listServices(chain: OnDeviceChain) {
        guard runTask == nil else { return }
        phase = .running("Listing RSD services…")
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let handshake = try await establish(chain: chain)
                await MainActor.run { [weak self] in
                    self?.emit("RSD services on this device (\(handshake.services.count)):")
                    for name in handshake.services.keys.sorted() {
                        self?.emit("  \(name) → port \(handshake.services[name]?.port ?? 0)")
                    }
                    self?.phase = .done("Listed \(handshake.services.count) service(s).")
                    self?.runTask = nil
                }
            } catch {
                await self.fail("RSD listing", error: error)
            }
        }
    }

    func cleanBooks(chain: OnDeviceChain, stagedPaths: [String] = []) {
        guard runTask == nil else { return }
        phase = .running("Dọn Books…")
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let handshake = try await establish(chain: chain)
                let access = try await afcAccess(chain: chain, handshake: handshake)
                let books = BooksState(access: access, log: { [weak self] line in
                    Task { @MainActor [weak self] in self?.lines.append(line) }
                })
                let report = await books.cleanBooks(stagedPaths: stagedPaths)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if report.isClean {
                        self.phase = .done("BOOKS DONE ✓")
                    } else {
                        self.phase = .failed("Cleanup incomplete: " +
                            report.failures.joined(separator: ", "))
                    }
                    self.runTask = nil
                }
            } catch {
                await self.fail("Dọn Books", error: error)
            }
        }
    }

    /// Experimental end-to-end staging: build archive + stream to the
    /// conduit (when RSD advertises it) + write Books.plist + verify what
    /// AFC can see. Stops honestly at whatever is unavailable.
    func stageArchive(chain: OnDeviceChain) {
        guard runTask == nil else { return }
        phase = .running("Staging archive…")
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let target: String
                do {
                    target = try AirlockArchive.normalizeTarget(self.targetDirectory)
                } catch {
                    throw OnDeviceChain.ChainError.stepFailed(
                        step: "target", reason: "unsafe target directory")
                }
                let token = (0..<10).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
                    .joined()
                let plan = BooksAttempt.plan(target: target, leaf: "airlift-canary-\(token).bin",
                                             token: token)
                let payload = BooksAttempt.canaryPayload(build: "on-device", nonce: token)
                let entries = try AirlockArchive.entries(target: target, payload: payload)
                let archive = AirlockArchive.archiveData(entries: entries)
                await self.emitLine("Archive built: \(entries.count) entries, \(archive.count) bytes " +
                    "(symlink p0/p1/p2/link → ../../../\(target.dropFirst()))")

                let handshake = try await establish(chain: chain)
                guard let conduitPort = self.conduitPort(in: handshake) else {
                    await self.emitLine("No streaming_zip_conduit port in RSD table " +
                        "(\(handshake.services.count) services) — cannot stage.")
                    await self.finishFailed("RSD does not advertise the conduit service; " +
                        "archive NOT sent. Service table is in the log above.")
                    return
                }
                await self.emitLine("Conduit service at port \(conduitPort) — streaming archive…")
                let conduitStream = try await TCPStream(host: chain.host, port: conduitPort,
                                                        timeout: 15)
                let conduit = StreamingZipConduit(stream: conduitStream, timeout: 30)
                let response = try await conduit.sendArchive(archive, mediaSubdir: plan.source)
                await self.emitLine("Conduit response: \(response)")
                conduitStream.close()

                let access = try await afcAccess(chain: chain, handshake: handshake)
                try await access.makeDirectory(path: "Books")
                try await access.makeDirectory(path: "Books/Sync")
                let books = try AirlockArchive.booksData(identifiers: plan.identifiers)
                try await access.write("Books/Sync/Books.plist", data: books)
                await self.emitLine("Books/Sync/Books.plist written (\(plan.identifiers.count) identifiers)")

                let linkOk = await access.exists("\(plan.source)/p0/p1/p2/link")
                let payloadOk = await access.exists("\(plan.source)/payload")
                await self.emitLine("Staged objects visible via AFC: link=\(linkOk) payload=\(payloadOk)")
                if !(linkOk && payloadOk) {
                    await self.finishFailed("Conduit accepted the archive but staged objects " +
                        "are not visible via AFC. Staged source: \(plan.source). Run Dọn Books to clean up.")
                    return
                }
                await MainActor.run { [weak self] in
                    self?.phase = .done("Staged \(plan.source). Target write needs the " +
                        "AirTraffic sync trigger (pending seam) — verify manually, then Dọn Books.")
                    self?.runTask = nil
                }
            } catch {
                await self.fail("Stage archive", error: error)
            }
        }
    }

    private func conduitPort(in handshake: RSDClient.Handshake) -> UInt16? {
        if let port = handshake.port(for: "com.apple.streaming_zip_conduit") {
            return port
        }
        for (name, service) in handshake.services {
            let lower = name.lowercased()
            if lower.contains("streaming_zip") || lower.contains("conduit") {
                return service.port
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func emitLine(_ line: String) async {
        AppLogger.airLift.info(line, event: "books")
        await MainActor.run { [weak self] in self?.lines.append(line) }
    }

    private func finishFailed(_ reason: String) async {
        await MainActor.run { [weak self] in
            self?.phase = .failed(reason)
            self?.runTask = nil
        }
    }

    private func fail(_ action: String, error: Error) async {
        let reason: String
        if let chainError = error as? OnDeviceChain.ChainError {
            switch chainError {
            case .stepFailed(let step, let message):
                reason = "\(action) failed at \(step): \(message)"
            default:
                reason = "\(action) failed: \(chainError.message)"
            }
        } else {
            reason = "\(action) failed: \(error.localizedDescription)"
        }
        AppLogger.airLift.error(reason, event: "books")
        await MainActor.run { [weak self] in
            self?.phase = .failed(reason)
            self?.runTask = nil
        }
    }
}

struct DonBooksView: View {
    @ObservedObject var guardVM: AirLiftLaunchGuard
    @StateObject private var model = DonBooksViewModel()

    var body: some View {
        Section {
            if !model.lines.isEmpty {
                ForEach(model.lines.indices, id: \.self) { index in
                    Text(model.lines[index])
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch model.phase {
            case .idle:
                Text("Books sync-state cleanup + exploit staging over the real RSD/AFC chain. Dọn Books reproduces the reference transcript; staging is experimental and reports exactly where it stops.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .running(let label):
                HStack {
                    ProgressView()
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .done(let summary):
                Label(summary, systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.listServices(chain: OnDeviceChain())
            } label: {
                Label("List RSD Services", systemImage: "list.bullet.rectangle")
            }
            .disabled(!guardVM.canStartAirLift || model.isRunning)
            Button {
                model.cleanBooks(chain: OnDeviceChain())
            } label: {
                Label("Dọn Books", systemImage: "books.vertical.fill")
            }
            .disabled(!guardVM.canStartAirLift || model.isRunning)
            HStack {
                Button {
                    model.stageArchive(chain: OnDeviceChain())
                } label: {
                    Label("Stage Archive (experimental)", systemImage: "doc.zipper")
                }
                .disabled(!guardVM.canStartAirLift || model.isRunning)
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .font(.footnote)
                } else if !model.lines.isEmpty {
                    Button("Clear") { model.clear() }
                        .font(.footnote)
                }
            }
            TextField("Target directory", text: $model.targetDirectory)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !guardVM.canStartAirLift {
                Text("Requires LocalDevVPN Connected and a valid Pairing File.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Dọn Books (RSD + AFC)")
        } footer: {
            Text("Cleanup and staging run entirely on-device through the tunnel. Writes outside the AFC scope additionally need the AirTraffic sync trigger (pending seam) — staging reports precisely where it stopped.")
        }
    }
}
