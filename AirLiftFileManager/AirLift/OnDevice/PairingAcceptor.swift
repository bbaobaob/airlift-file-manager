import CryptoKit
import Foundation

/// Device-initiated pair-setup server (M1–M6). Direct port of idevice
/// `PairableHost::accept` (responder.rs): the device connected to our
/// advertised `_remotepairing-pairable-host._tcp` service and drives the
/// conversation; we answer handshake + SRP pair-setup, display the PIN for
/// the user to type on the device, then save the fresh RpPairingFile.
///
/// All envelopes use originatedBy "device" (responder role).
struct PairingAcceptor {
    let stream: TCPStream
    let identity: PairingHost.HostIdentity
    let pairingStore: any PairingStoring
    /// Called with the 6-digit PIN to display; must return when shown.
    let pinCallback: (String) async -> Void
    /// Fine-grained step events (UI transcript + diagnostics).
    let progress: (String) async -> Void
    private var sequence = 0

    init(stream: TCPStream, identity: PairingHost.HostIdentity,
         pairingStore: any PairingStoring,
         pinCallback: @escaping (String) async -> Void,
         progress: @escaping (String) async -> Void = { _ in }) {
        self.stream = stream
        self.identity = identity
        self.pairingStore = pairingStore
        self.pinCallback = pinCallback
        self.progress = progress
    }

    private func emit(_ line: String) async {
        AppLogger.pairing.info(line, event: "pairing.steps")
        await progress(line)
    }

    /// Runs handshake + M1–M6. Returns the paired peer device and persists
    /// the pairing record through the normal validated import path.
    mutating func accept() async throws -> PairingHost.PeerDevice {
        try await handshake()
        return try await pairSetup()
    }

    // MARK: - Handshake

    private mutating func handshake() async throws {
        let request = try await receivePlain()
        guard RPPairingWire.navigate(request, "request", "_0", "handshake", "_0") != nil else {
            throw PairingHost.PairError.protocolError("missing device handshake request")
        }
        if let attempt = RPPairingWire.navigate(
            request, "request", "_0", "handshake", "_0",
            "hostOptions", "attemptPairVerify") as? Bool,
           attempt {
            throw PairingHost.PairError.protocolError(
                "device requested pair-verify; only device-initiated pair-setup is supported")
        }
        await emit("Device handshake received")
        let reply = PairingHost.handshakeReply(identity: identity)
        try await sendPlain(reply)
        await emit("Handshake reply sent (pair-setup offered)")
    }

    // MARK: - Pair-setup M1–M6

    private mutating func pairSetup() async throws -> PairingHost.PeerDevice {
        // M1.
        let m1 = try await receivePairingTLV()
        try expectState(m1, 1)
        await emit("M1 received — generating salt, PIN and ephemeral key")

        // M2: salt + PIN + verifier + ephemeral B (retry until 384 bytes).
        let reducer = SRPBigUInt.BarrettReducer(modulus: SRP3072.modulus)
        let salt = randomBytes(16)
        let pin = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let x = SRP3072.x(salt: salt, password: Data(pin.utf8))
        let v = SRP3072.verifier(x: x, reducer: reducer)
        let k = SRP3072.k()
        let bBytes: [UInt8]
        let bPubBytes: [UInt8]
        while true {
            let candidate = randomBytes(32)
            let candidateB = SRP3072.serverPublic(
                b: SRPBigUInt(bytesBE: Array(candidate)), v: v, k: k, reducer: reducer)
            if let fixed = candidateB.fixedBE(SRP3072.nLength) {
                bBytes = Array(candidate)
                bPubBytes = fixed
                break
            }
        }
        let b = SRPBigUInt(bytesBE: bBytes)
        await emit("M2 sent (salt + ephemeral key) — PIN ready")
        await pinCallback(pin)
        var m2: [TLV8.Entry] = [
            TLV8.Entry(.state, Data([0x02])),
            TLV8.Entry(.salt, salt),
        ]
        m2.append(contentsOf: chunked(.publicKey, Data(bPubBytes)))
        try await sendPairingTLV(m2)

        // M3: A + client proof (arrives after the user types the PIN).
        let m3 = try await receivePairingTLV()
        try ensureNoError(m3)
        try expectState(m3, 3)
        await emit("M3 received — verifying PIN proof")
        let aBytes = collect(m3, .publicKey)
        guard let proofEntry = m3.first(where: { $0.component == .proof }),
              !aBytes.isEmpty, !proofEntry.data.isEmpty else {
            throw PairingHost.PairError.protocolError("M3 missing public key or proof")
        }
        let aPub = SRPBigUInt(bytesBE: Array(aBytes))
        // Safeguard against malicious A (idevice: reject A % N == 0).
        if reducer.reduce(aPub) == .zero {
            throw PairingHost.PairError.srpFailed("illegal client ephemeral (A % N == 0)")
        }
        let u = SRP3072.u(clientPublic: aPub,
                           serverPublic: SRPBigUInt(bytesBE: bPubBytes))
        let sessionKey = SRP3072.sessionKey(
            clientPublic: aPub, verifier: v, u: u, b: b, reducer: reducer)
        let expectedM1 = SRP3072.m1(clientPublic: aPub,
                                    serverPublic: SRPBigUInt(bytesBE: bPubBytes),
                                    key: sessionKey, salt: salt)
        guard constantTimeEqual(expectedM1, proofEntry.data) else {
            // Wrong PIN (or attack): tell the device authentication failed.
            try await sendPairingTLV(try TLV8.deserialize(PairingHost.authFailureTLV()))
            throw PairingHost.PairError.srpFailed(
                "client proof mismatch — wrong PIN typed on the device?")
        }

        await emit("PIN verified — sending server proof (M4)")
        // M4: server proof.
        let serverProof = SRP3072.m2(clientPublic: aPub, m1: expectedM1, key: sessionKey)
        try await sendPairingTLV([
            TLV8.Entry(.state, Data([0x04])),
            TLV8.Entry(.proof, serverProof),
        ])

        // Setup cipher for M5/M6.
        let setupKey = SymmetricKey(data: hkdfSHA512(
            salt: Data("Pair-Setup-Encrypt-Salt".utf8),
            ikm: sessionKey,
            info: Data("Pair-Setup-Encrypt-Info".utf8)))

        // M5: device identity.
        let m5 = try await receivePairingTLV()
        try ensureNoError(m5)
        try expectState(m5, 5)
        await emit("M5 received — decrypting device identity")
        let encBytes = collect(m5, .encryptedData)
        guard !encBytes.isEmpty else {
            throw PairingHost.PairError.protocolError("M5 missing EncryptedData")
        }
        let m5plain = try decryptChaCha(key: setupKey, nonce: psNonce("PS-Msg05"),
                                        ciphertext: encBytes)
        let m5tlv = try TLV8.deserialize(m5plain)
        let peer = try Self.parsePeerDevice(m5tlv)

        // M6: our identity.
        let m6plain = try buildAccessoryIdentity(sessionKey: sessionKey)
        let m6cipher = try encryptChaCha(key: setupKey, nonce: psNonce("PS-Msg06"),
                                         plaintext: m6plain)
        var m6 = chunked(.encryptedData, m6cipher)
        m6.append(TLV8.Entry(.state, Data([0x06])))
        try await sendPairingTLV(m6)

        // Persist the fresh pairing record (our keys + identifier + device altIRK).
        let record: [String: Any] = [
            "public_key": identity.publicKey,
            "private_key": identity.seed,
            "identifier": identity.identifier,
            "alt_irk": peer.altIrk,
        ]
        let recordData = try PropertyListSerialization.data(
            fromPropertyList: record, format: .xml, options: 0)
        let result = pairingStore.importRecord(recordData)
        guard result.isValid else {
            throw PairingHost.PairError.protocolError(
                "fresh pairing record failed validation: \(result.message)")
        }
        await emit("M6 sent — pairing record saved to Keychain")
        return peer
    }

    // MARK: - M6 + M5 helpers (pure logic, tested)

    static func accessorySignBuffer(accessoryX: Data, identifier: String,
                                    ltpk: Data) -> Data {
        var out = Data()
        out.append(contentsOf: accessoryX)
        out.append(contentsOf: Data(identifier.utf8))
        out.append(contentsOf: ltpk)
        return out
    }

    func buildAccessoryIdentity(sessionKey: Data) throws -> Data {
        // AccessoryX = HKDF(salt "Pair-Setup-Accessory-Sign-Salt", session_key,
        // info "Pair-Setup-Accessory-Sign-Info"); sign(AccessoryX||id||LTPK).
        let accessoryX = hkdfSHA512(salt: Data("Pair-Setup-Accessory-Sign-Salt".utf8),
                                    ikm: sessionKey,
                                    info: Data("Pair-Setup-Accessory-Sign-Info".utf8))
        let signbuf = Self.accessorySignBuffer(accessoryX: accessoryX,
                                               identifier: identity.identifier,
                                               ltpk: identity.publicKey)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.seed)
        let signature = try privateKey.signature(for: signbuf)
        let info = OPACK.encode(.dictionary([
            ("altIRK", .data(identity.altIrk)),
            ("btAddr", .string("11:22:33:44:55:66")),
            ("mac", .data(Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))),
            ("remotepairing_serial_number", .string("AAAAAAAAAAAA")),
            ("accountID", .string(identity.identifier)),
            ("remotepairing_udid", .string("")),
            ("model", .string(identity.model)),
            ("name", .string(identity.name)),
        ]))
        return TLV8.serialize([
            TLV8.Entry(.identifier, Data(identity.identifier.utf8)),
            TLV8.Entry(.publicKey, identity.publicKey),
            TLV8.Entry(.signature, signature),
            TLV8.Entry(.info, info),
        ])
    }

    static func parsePeerDevice(_ entries: [TLV8.Entry]) throws -> PairingHost.PeerDevice {
        guard let infoEntry = entries.first(where: { $0.component == .info }) else {
            throw PairingHost.PairError.protocolError("M5 identity missing Info payload")
        }
        let decoded: OPACK.Value
        do {
            decoded = try OPACK.decode(infoEntry.data)
        } catch {
            throw PairingHost.PairError.protocolError("M5 Info is not valid OPACK: \(error)")
        }
        guard case .dictionary(let dict) = decoded else {
            throw PairingHost.PairError.protocolError("M5 Info is not a dictionary")
        }
        func string(_ key: String) -> String {
            for (name, value) in dict {
                if name == key, case .string(let text) = value { return text }
            }
            return ""
        }
        func blob(_ key: String) -> Data {
            for (name, value) in dict {
                if name == key, case .data(let data) = value { return data }
            }
            return Data()
        }
        let altIrk = blob("altIRK")
        guard altIrk.count == 16 else {
            throw PairingHost.PairError.protocolError("peer altIRK is not 16 bytes")
        }
        return PairingHost.PeerDevice(accountID: string("accountID"), altIrk: altIrk,
                                      model: string("model"), name: string("name"),
                                      udid: string("remotepairing_udid"))
    }

    // MARK: - Transport helpers

    private mutating func sendPlain(_ value: [String: Any]) async throws {
        try await stream.write(RPPairingWire.frame(jsonObject:
            RPPairingWire.plainEnvelope(value: value, sequence: sequence,
                                        originatedBy: "device")))
        sequence += 1
    }

    private mutating func sendPairingTLV(_ entries: [TLV8.Entry]) async throws {
        let tlv = TLV8.serialize(entries)
        try await sendPlain(["event": ["_0": ["pairingData": ["_0": [
            "data": tlv.base64EncodedString(),
            "startNewSession": false,
            "kind": "setupManualPairing",
        ]]]]])
    }

    private func receivePlain() async throws -> Any {
        let json: Any
        do {
            json = try await stream.readRPPairingFrame(timeout: 120)
        } catch let error as TCPStream.StreamError {
            switch error {
            case .closed:
                throw PairingHost.PairError.protocolError(
                    "device closed the connection mid-pairing")
            case .timeout:
                throw PairingHost.PairError.timeout(
                    "timed out waiting for the device message")
            case .connectionFailed(let detail):
                throw PairingHost.PairError.protocolError(
                    "connection failed: \(detail)")
            }
        }
        guard let body = RPPairingWire.plainBody(json) else {
            throw PairingHost.PairError.protocolError("expected plain RPPairing message")
        }
        return body
    }

    private func receivePairingTLV() async throws -> [TLV8.Entry] {
        let body = try await receivePlain()
        guard let dataB64 = RPPairingWire.navigate(
            body, "event", "_0", "pairingData", "_0", "data") as? String,
              let tlvBytes = Data(base64Encoded: dataB64) else {
            throw PairingHost.PairError.protocolError("missing pairingData TLV in device message")
        }
        do {
            return try TLV8.deserialize(tlvBytes)
        } catch {
            throw PairingHost.PairError.protocolError("device TLV is malformed")
        }
    }

    /// Concatenates every entry of one component type (fragmented values
    /// arrive as multiple ≤255-byte entries; using only the first silently
    /// corrupts 384-byte keys and M5 ciphertext).
    private func collect(_ entries: [TLV8.Entry], _ component: TLV8.Component) -> Data {
        entries.filter { $0.component == component }
            .reduce(Data(), { $0 + $1.data })
    }

    private func expectState(_ entries: [TLV8.Entry], _ expected: UInt8) throws {
        guard let state = entries.first(where: { $0.component == .state })?.data.first,
              state == expected else {
            throw PairingHost.PairError.protocolError(
                "unexpected pair-setup state (expected \(expected))")
        }
    }

    private func ensureNoError(_ entries: [TLV8.Entry]) throws {
        if entries.contains(where: { $0.component == .errorResponse }) {
            throw PairingHost.PairError.protocolError("device returned a pairing error")
        }
    }

    private func chunked(_ component: TLV8.Component, _ data: Data) -> [TLV8.Entry] {
        var out: [TLV8.Entry] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: 255, limitedBy: data.endIndex) ?? data.endIndex
            out.append(TLV8.Entry(component, Data(data[offset..<end])))
            offset = end
        }
        if out.isEmpty {
            out.append(TLV8.Entry(component, Data()))
        }
        return out
    }

    private func randomBytes(_ count: Int) -> Data {
        var out = Data(count: count)
        for i in out.indices { out[i] = UInt8.random(in: 0...255) }
        return out
    }

    private func hkdfSHA512(salt: Data, ikm: Data, info: Data) -> Data {
        let okm = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt, info: info, outputByteCount: 32)
        return okm.withUnsafeBytes { Data($0) }
    }

    private func psNonce(_ label: String) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data([0x00, 0x00, 0x00, 0x00]) + Data(label.utf8))
    }

    private func decryptChaCha(key: SymmetricKey, nonce: ChaChaPoly.Nonce,
                               ciphertext: Data) throws -> Data {
        // chacha20poly1305 crate format: ciphertext || 16-byte tag.
        guard ciphertext.count >= 16 else {
            throw PairingHost.PairError.protocolError("ciphertext too short")
        }
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16))
        do {
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw PairingHost.PairError.srpFailed("M5 decrypt failed")
        }
    }

    private func encryptChaCha(key: SymmetricKey, nonce: ChaChaPoly.Nonce,
                               plaintext: Data) throws -> Data {
        do {
            let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
            return sealed.ciphertext + sealed.tag
        } catch {
            throw PairingHost.PairError.srpFailed("M6 encrypt failed")
        }
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
        return diff == 0
    }
}
