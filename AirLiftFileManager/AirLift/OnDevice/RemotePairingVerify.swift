import CryptoKit
import Foundation

/// Pair-verify handshake against `_remotepairing._tcp` using a stored
/// StikPair remote-pairing record. Direct port of idevice
/// `RemotePairingClient::attempt_pair_verify` + `validate_pairing`
/// (`remote_pairing/mod.rs`):
///
/// 1. attemptPairVerify (wireProtocolVersion 19) → expect handshake reply.
/// 2. M1 `verifyManualPairing` (State=01 + ephemeral X25519 pubkey).
/// 3. Device X25519 pubkey → X25519 DH = `encryptionKey` (TLS-PSK later).
/// 4. HKDF-SHA512(salt "Pair-Verify-Encrypt-Salt", info
///    "Pair-Verify-Encrypt-Info") → ChaCha20Poly1305 key.
/// 5. Ed25519-sign(eph_pub || identifier || device_pub) with the record's
///    private key → M3 (State=03 + EncryptedData, fixed PV-Msg03 nonce).
///
/// Crypto mapping: CryptoKit Curve25519 KeyAgreement/Signing, HKDF<SHA512>
/// (note: empty-salt HKDF uses 64 zero bytes to match Rust hkdf None),
/// ChaChaPoly with explicit 12-byte nonce.
struct RemotePairingVerify {
    struct Credential {
        let privateKey: Curve25519.Signing.PrivateKey
        let identifier: String
    }

    enum VerifyError: Error, Equatable {
        case badCredential(String)
        case protocolError(String)
        case cryptoFailure(String)
    }

    let stream: any DataStream
    private(set) var sequence = 0
    private var encryptedSequence: UInt64 = 0

    init(stream: any DataStream) {
        self.stream = stream
    }

    static func credential(from recordData: Data) throws -> Credential {
        guard let dict = (try? PropertyListSerialization.propertyList(
            from: recordData, format: nil)) as? [String: Any],
              let seed = dict["private_key"] as? Data, seed.count == 32,
              let identifier = dict["identifier"] as? String, !identifier.isEmpty else {
            throw VerifyError.badCredential("record lacks a 32-byte private_key or identifier")
        }
        do {
            return Credential(privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed),
                              identifier: identifier)
        } catch {
            throw VerifyError.badCredential("private_key is not a valid Ed25519 seed")
        }
    }

    /// Runs the full pair-verify. Returns the 32-byte X25519 shared secret
    /// that doubles as the TLS-PSK for the tunnel step.
    mutating func run(credential: Credential) async throws -> Data {
        try await attemptPairVerify()
        return try await validatePairing(credential: credential)
    }

    // MARK: - Step 1: attemptPairVerify

    private mutating func attemptPairVerify() async throws {
        let request = RPPairingWire.attemptPairVerifyRequest()
        try await sendPlain(RPPairingWire.plainEnvelope(value: request, sequence: sequence))
        sequence += 1
        let reply = try await receivePlain()
        guard RPPairingWire.navigate(reply, "response", "_1", "handshake", "_0") != nil else {
            throw VerifyError.protocolError("missing handshake reply to attemptPairVerify")
        }
    }

    // MARK: - Step 2: validatePairing (X25519 + signature)

    private mutating func validatePairing(credential: Credential) async throws -> Data {
        // Ephemeral X25519.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPub = Data(ephemeral.publicKey.rawRepresentation)

        // M1.
        let m1 = RPPairingWire.m1TLV(ephemeralPublicKey: ephemeralPub)
        let m1msg = RPPairingWire.pairingDataMessage(
            tlvBase64: m1.base64EncodedString(), startNewSession: true)
        try await sendPlain(RPPairingWire.plainEnvelope(value: m1msg, sequence: sequence))
        sequence += 1

        // Device response → TLV → device X25519 public key.
        let m1reply = try await receivePairingTLV()
        guard !m1reply.contains(where: { $0.component == .errorResponse }) else {
            throw VerifyError.protocolError("device refused pair-verify (ErrorResponse)")
        }
        guard let devicePubEntry = m1reply.first(where: { $0.component == .publicKey }),
              devicePubEntry.data.count == 32 else {
            throw VerifyError.protocolError("missing 32-byte device public key in pair-verify reply")
        }
        let devicePubBytes = Array(devicePubEntry.data)

        // X25519 DH → encryption key (raw shared secret).
        let devicePub: Curve25519.KeyAgreement.PublicKey
        do {
            devicePub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePubBytes)
        } catch {
            throw VerifyError.cryptoFailure("device public key is not a valid X25519 key")
        }
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: devicePub)
        } catch {
            throw VerifyError.cryptoFailure("X25519 key agreement failed")
        }
        let encryptionKey = sharedSecret.withUnsafeBytes { Data($0) }

        // HKDF-SHA512 → ChaCha20Poly1305 key.
        let hkdfKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: encryptionKey),
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            info: Data("Pair-Verify-Encrypt-Info".utf8),
            outputByteCount: 32)
        let cipherKey = SymmetricKey(data: hkdfKey.withUnsafeBytes { Data($0) })

        // Ed25519 signature over eph_pub || identifier || device_pub.
        let signbuf = RPPairingWire.signBuffer(ephemeralPublicKey: ephemeralPub,
                                               identifier: credential.identifier,
                                               devicePublicKey: devicePubEntry.data)
        let signature: Data
        do {
            signature = try credential.privateKey.signature(for: signbuf)
        } catch {
            throw VerifyError.cryptoFailure("Ed25519 signing failed")
        }

        // M3: encrypt Identifier+Signature TLV with the FIXED PV-Msg03 nonce.
        let m3plain = RPPairingWire.m3PlaintextTLV(identifier: credential.identifier,
                                                   signature: signature)
        let nonce = try ChaChaPoly.Nonce(data: RPPairingWire.pairVerifyNonce)
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(m3plain, using: cipherKey, nonce: nonce)
        } catch {
            throw VerifyError.cryptoFailure("ChaCha20Poly1305 encryption failed")
        }
        let ciphertext = sealed.ciphertext + sealed.tag
        let m3 = RPPairingWire.m3EnvelopeTLV(ciphertext: ciphertext)
        let m3msg = RPPairingWire.pairingDataMessage(
            tlvBase64: m3.base64EncodedString(), startNewSession: false)
        try await sendPlain(RPPairingWire.plainEnvelope(value: m3msg, sequence: sequence))
        sequence += 1

        let m3reply = try await receivePairingTLV()
        guard !m3reply.contains(where: { $0.component == .errorResponse }) else {
            throw VerifyError.protocolError("device rejected pair-verify signature (ErrorResponse)")
        }
        return encryptionKey
    }

    /// Encrypted request/response helper (createListener): encrypt JSON with
    /// the main client cipher, sequence-derived nonce; decrypt reply with the
    /// server cipher and the SAME nonce. Direct port of
    /// `send_receive_encrypted_request`.
    static func encryptedNonce(sequence: UInt64) -> Data {
        var out = Data(count: 12)
        var le = sequence.littleEndian
        withUnsafeBytes(of: &le) { out.replaceSubrange(0..<8, with: $0) }
        return out
    }

    static func mainCiphers(encryptionKey: Data) -> (client: SymmetricKey, server: SymmetricKey) {
        func derive(_ info: String) -> SymmetricKey {
            // Rust hkdf None salt == HashLen (64) zero bytes — CryptoKit wants
            // it spelled out explicitly.
            let okm = HKDF<SHA512>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: encryptionKey),
                salt: Data(repeating: 0, count: 64),
                info: Data(info.utf8),
                outputByteCount: 32)
            return SymmetricKey(data: okm.withUnsafeBytes { Data($0) })
        }
        return (derive("ClientEncrypt-main"), derive("ServerEncrypt-main"))
    }

    /// Send a request to create a TCP tunnel listener on the device.
    /// Returns the port the device listens on. Direct port of
    /// `create_tcp_listener` (encrypted request via the main ciphers,
    /// sequence-derived nonce, shared for request+response).
    mutating func createTunnelListener(encryptionKey: Data) async throws -> UInt16 {
        let (clientKey, serverKey) = Self.mainCiphers(encryptionKey: encryptionKey)
        let request = RPPairingWire.createListenerRequest(
            encryptionKeyBase64: encryptionKey.base64EncodedString())
        let plaintext = try JSONSerialization.data(withJSONObject: request, options: [])
        let nonce = Self.encryptedNonce(sequence: encryptedSequence)
        let sealed = try ChaChaPoly.seal(plaintext, using: clientKey,
                                         nonce: ChaChaPoly.Nonce(data: nonce))
        let ciphertext = sealed.ciphertext + sealed.tag
        try await sendRaw(RPPairingWire.frame(jsonObject:
            RPPairingWire.encryptedEnvelope(ciphertextBase64: ciphertext.base64EncodedString(),
                                            sequence: sequence)))
        sequence += 1

        let replyJSON = try await stream.readRPPairingFrame()
        guard let b64 = RPPairingWire.encryptedBodyBase64(replyJSON),
              let encrypted = Data(base64Encoded: b64) else {
            throw VerifyError.protocolError("missing streamEncrypted createListener reply")
        }
        let opened: Data
        do {
            opened = try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: nonce + encrypted), using: serverKey)
        } catch {
            throw VerifyError.cryptoFailure("createListener reply decrypt failed")
        }
        encryptedSequence += 1
        guard let reply = try? JSONSerialization.jsonObject(with: opened, options: []),
              let portNumber = RPPairingWire.navigate(
                  reply, "response", "_1", "createListener", "port") as? NSNumber else {
            throw VerifyError.protocolError("missing response._1.createListener.port")
        }
        return portNumber.uint16Value
    }

    // MARK: - Transport helpers

    private func sendRaw(_ data: Data) async throws {
        try await stream.write(data)
    }

    private func sendPlain(_ envelope: [String: Any]) async throws {
        try await stream.write(RPPairingWire.frame(jsonObject: envelope))
    }

    private func receivePlain() async throws -> Any {
        let json = try await stream.readRPPairingFrame()
        guard let body = RPPairingWire.plainBody(json) else {
            throw VerifyError.protocolError("expected plain RPPairing message")
        }
        return body
    }

    private func receivePairingTLV() async throws -> [TLV8.Entry] {
        let body = try await receivePlain()
        guard let dataB64 = RPPairingWire.navigate(body, "event", "_0", "pairingData", "_0", "data") as? String,
              let tlvBytes = Data(base64Encoded: dataB64) else {
            throw VerifyError.protocolError("missing event._0.pairingData._0.data in reply")
        }
        do {
            return try TLV8.deserialize(tlvBytes)
        } catch {
            throw VerifyError.protocolError("pair-verify reply is not valid TLV8")
        }
    }
}
