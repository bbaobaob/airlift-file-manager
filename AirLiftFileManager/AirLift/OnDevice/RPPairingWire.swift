import Foundation

/// RPPairing wire framing + pair-verify message builders.
/// Direct port of idevice `remote_pairing/socket.rs` (RpPairingSocket) and the
/// verifyManualPairing messages in `remote_pairing/mod.rs`.
///
/// Wire format: `"RPPairing"` magic + u16-BE JSON length + UTF-8 JSON.
/// Envelopes: `{"message":{"plain":{"_0":VALUE}},"originatedBy":"host",
/// "sequenceNumber":N}` or `{"message":{"streamEncrypted":{"_0":BASE64}},
/// ...}`. Binary blobs inside JSON are base64 strings (rppairing rule).
enum RPPairingWire {
    static let magic = Data("RPPairing".utf8)
    static let wireProtocolVersion = 19
    static let originatedBy = "host"

    /// Fixed 12-byte nonce for the pair-verify Msg03 encryption.
    static let pairVerifyNonce = Data([0x00, 0x00, 0x00, 0x00]) + Data("PV-Msg03".utf8)

    enum WireError: Error, Equatable {
        case badMagic
        case truncated
        case invalidJSON
        case missingField(String)
    }

    // MARK: - Framing

    static func frame(jsonObject: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        var out = Data()
        out.append(magic)
        out.append(contentsOf: withBE16(UInt16(body.count)))
        out.append(contentsOf: body)
        return out
    }

    /// Splits one frame off the front of `buffer`; returns frame JSON + rest.
    static func popFrame(from buffer: Data) throws -> (json: Any, rest: Data)? {
        guard buffer.count >= magic.count + 2 else { return nil }
        guard buffer.prefix(magic.count) == magic else { throw WireError.badMagic }
        let length = Int(be16(buffer, at: magic.count))
        guard buffer.count >= magic.count + 2 + length else { return nil }
        let start = buffer.startIndex + magic.count + 2
        let end = start + length
        let json = try JSONSerialization.jsonObject(with: buffer[start..<end], options: [])
        return (json, Data(buffer[end...]))
    }

    // MARK: - Envelopes

    static func plainEnvelope(value: Any, sequence: Int,
                              originatedBy: String = "host") -> [String: Any] {
        ["message": ["plain": ["_0": value]],
         "originatedBy": originatedBy,
         "sequenceNumber": sequence]
    }

    static func encryptedEnvelope(ciphertextBase64: String, sequence: Int,
                                  originatedBy: String = "host") -> [String: Any] {
        ["message": ["streamEncrypted": ["_0": ciphertextBase64]],
         "originatedBy": originatedBy,
         "sequenceNumber": sequence]
    }

    static func pairingDataMessage(tlvBase64: String, kind: String = "verifyManualPairing",
                                   startNewSession: Bool) -> [String: Any] {
        ["event": ["_0": ["pairingData": ["_0": [
            "data": tlvBase64,
            "kind": kind,
            "startNewSession": startNewSession,
        ]]]]]
    }

    // MARK: - verifyManualPairing builders

    /// M1: State=0x01 + ephemeral X25519 public key.
    static func m1TLV(ephemeralPublicKey: Data) -> Data {
        TLV8.serialize([
            TLV8.Entry(.state, Data([0x01])),
            TLV8.Entry(.publicKey, ephemeralPublicKey),
        ])
    }

    /// signbuf = eph_pub(32) || identifier(utf8) || device_pub(32).
    static func signBuffer(ephemeralPublicKey: Data, identifier: String,
                           devicePublicKey: Data) -> Data {
        var out = Data()
        out.append(contentsOf: ephemeralPublicKey)
        out.append(contentsOf: Data(identifier.utf8))
        out.append(contentsOf: devicePublicKey)
        return out
    }

    /// M3 plaintext TLV: Identifier + Signature (encrypted by caller).
    static func m3PlaintextTLV(identifier: String, signature: Data) -> Data {
        TLV8.serialize([
            TLV8.Entry(.identifier, Data(identifier.utf8)),
            TLV8.Entry(.signature, signature),
        ])
    }

    /// M3 envelope TLV: State=0x03 + EncryptedData.
    static func m3EnvelopeTLV(ciphertext: Data) -> Data {
        TLV8.serialize([
            TLV8.Entry(.state, Data([0x03])),
            TLV8.Entry(.encryptedData, ciphertext),
        ])
    }

    /// attemptPairVerify request body.
    static func attemptPairVerifyRequest() -> [String: Any] {
        ["request": ["_0": ["handshake": ["_0": [
            "hostOptions": ["attemptPairVerify": true],
            "wireProtocolVersion": wireProtocolVersion,
        ]]]]]
    }

    /// Encrypted createListener request (plaintext dict; caller encrypts).
    static func createListenerRequest(encryptionKeyBase64: String) -> [String: Any] {
        ["request": ["_0": ["createListener": [
            "key": encryptionKeyBase64,
            "transportProtocolType": "tcp",
        ]]]]
    }

    // MARK: - Response navigation (JSON dicts; no exceptions for shape)

    static func navigate(_ json: Any, _ path: String...) -> Any? {
        var current: Any? = json
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    /// message.plain._0 (recv_plain plain branch).
    static func plainBody(_ frameJSON: Any) -> Any? {
        navigate(frameJSON, "message", "plain", "_0")
    }

    /// message.streamEncrypted._0 base64 (encrypted branch).
    static func encryptedBodyBase64(_ frameJSON: Any) -> String? {
        navigate(frameJSON, "message", "streamEncrypted", "_0") as? String
    }

    // MARK: - Little helpers (internal for tests)

    static func withBE16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func be16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[data.startIndex + offset]) << 8) | UInt16(data[data.startIndex + offset + 1])
    }
}
