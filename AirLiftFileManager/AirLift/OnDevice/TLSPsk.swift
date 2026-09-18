import CommonCrypto
import CryptoKit
import Foundation

/// Minimal TLS 1.2 PSK client. Direct port of idevice
/// `remote_pairing/tls_psk.rs` (pure-Rust TLS 1.2 PSK-AES-CBC-SHA* — no
/// external TLS library), offering `TLS_PSK_WITH_AES_256_CBC_SHA384`
/// (0x00AF, preferred by iOS) with `TLS_PSK_WITH_AES_128_CBC_SHA` (0x008C)
/// fallback. Only what the tunnel handshake needs: client auth via PSK
/// (the pair-verify encryption key), records, Finished verification.
enum TLSPsk {
    // MARK: - Constants

    static let version: [UInt8] = [0x03, 0x03]
    static let ctHandshake: UInt8 = 0x16
    static let ctChangeCipherSpec: UInt8 = 0x14
    static let ctApplicationData: UInt8 = 0x17
    static let ctAlert: UInt8 = 21
    static let hsClientHello: UInt8 = 0x01
    static let hsServerHello: UInt8 = 0x02
    static let hsServerHelloDone: UInt8 = 0x0E
    static let hsClientKeyExchange: UInt8 = 0x10
    static let hsFinished: UInt8 = 0x14
    static let maxPlaintext = 16384

    enum Suite: Equatable {
        case aes128CbcSha      // 0x008C: 16B key, 20B MAC (SHA1), PRF SHA256
        case aes256CbcSha384   // 0x00AF: 32B key, 48B MAC (SHA384), PRF SHA384

        static let offered: [[UInt8]] = [[0x00, 0xAF], [0x00, 0x8C]]

        static func from(bytes: [UInt8]) -> Suite? {
            switch bytes {
            case [0x00, 0x8C]: return .aes128CbcSha
            case [0x00, 0xAF]: return .aes256CbcSha384
            default: return nil
            }
        }

        var encKeyLength: Int {
            switch self {
            case .aes128CbcSha: return 16
            case .aes256CbcSha384: return 32
            }
        }

        var macLength: Int {
            switch self {
            case .aes128CbcSha: return 20
            case .aes256CbcSha384: return 48
            }
        }
    }

    enum TLSError: Error, Equatable {
        case alert(level: UInt8, description: UInt8)
        case unexpectedRecord(UInt8)
        case unsupportedCipher([UInt8])
        case macFailure
        case cryptoFailure(String)
        case badFinished
    }

    struct KeyBlock {
        let clientMacKey: Data
        let serverMacKey: Data
        let clientWriteKey: Data
        let serverWriteKey: Data
        let suite: Suite
    }

    // MARK: - PRF / key schedule (pure, tested structurally)

    static func hmac(key: Data, data: Data, suite: Suite) -> Data {
        switch suite {
        case .aes128CbcSha:
            // PRF hash is SHA256 even though record MACs use SHA1.
            Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        case .aes256CbcSha384:
            Data(HMAC<SHA384>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
    }

    /// TLS 1.2 P_hash PRF with the suite's hash.
    static func prf(secret: Data, label: Data, seed: Data, length: Int, suite: Suite) -> Data {
        let labelSeed = label + seed
        var a = hmac(key: secret, data: labelSeed, suite: suite)
        var out = Data()
        while out.count < length {
            out.append(contentsOf: hmac(key: secret, data: a + labelSeed, suite: suite))
            a = hmac(key: secret, data: a, suite: suite)
        }
        return out.prefix(length)
    }

    /// PSK premaster secret (RFC 4279 §2).
    static func premaster(psk: Data) -> Data {
        var out = Data()
        out.append(contentsOf: withBE16(UInt16(psk.count)))
        out.append(contentsOf: Data(repeating: 0, count: psk.count))
        out.append(contentsOf: withBE16(UInt16(psk.count)))
        out.append(contentsOf: psk)
        return out
    }

    static func masterSecret(psk: Data, clientRandom: Data, serverRandom: Data,
                             suite: Suite) -> Data {
        prf(secret: premaster(psk: psk), label: Data("master secret".utf8),
            seed: clientRandom + serverRandom, length: 48, suite: suite)
    }

    static func keyBlock(master: Data, clientRandom: Data, serverRandom: Data,
                         suite: Suite) -> KeyBlock {
        let total = suite.macLength * 2 + suite.encKeyLength * 2
        let kb = prf(secret: master, label: Data("key expansion".utf8),
                     seed: serverRandom + clientRandom, length: total, suite: suite)
        var pos = 0
        func take(_ n: Int) -> Data {
            defer { pos += n }
            return kb[pos..<(pos + n)]
        }
        return KeyBlock(clientMacKey: take(suite.macLength),
                        serverMacKey: take(suite.macLength),
                        clientWriteKey: take(suite.encKeyLength),
                        serverWriteKey: take(suite.encKeyLength),
                        suite: suite)
    }

    // MARK: - Record protection

    static func computeMac(macKey: Data, sequence: UInt64, contentType: UInt8,
                           data: Data, suite: Suite) -> Data {
        var buf = Data()
        buf.append(contentsOf: withBE64(sequence))
        buf.append(contentsOf: [contentType, 0x03, 0x03])
        buf.append(contentsOf: withBE16(UInt16(data.count)))
        buf.append(contentsOf: data)
        switch suite {
        case .aes128CbcSha:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(
                for: buf, using: SymmetricKey(data: macKey)))
        case .aes256CbcSha384:
            return Data(HMAC<SHA384>.authenticationCode(
                for: buf, using: SymmetricKey(data: macKey)))
        }
    }

    static func cbcCrypt(key: Data, iv: Data, data: Data, encrypt: Bool) throws -> Data {
        precondition(data.count % 16 == 0, "CBC input must be block-aligned (we pad manually)")
        var out = Data(count: data.count)
        var moved = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0), // CBC + no padding (manual PKCS#7)
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw TLSError.cryptoFailure("AES-CBC status \(status)")
        }
        return out.prefix(moved)
    }

    static func randomBytes(_ count: Int) -> Data {
        var out = Data(count: count)
        for i in out.indices { out[i] = UInt8.random(in: 0...255) }
        return out
    }

    static func encryptRecord(keys: KeyBlock, sequence: UInt64, contentType: UInt8,
                              plaintext: Data) throws -> Data {
        let mac = computeMac(macKey: keys.clientMacKey, sequence: sequence,
                             contentType: contentType, data: plaintext, suite: keys.suite)
        var payload = plaintext + mac
        // Manual PKCS#7 (block size 16 for both suites).
        let padLength = 16 - (payload.count % 16)
        payload.append(contentsOf: Data(repeating: UInt8(padLength - 1), count: padLength))
        let iv = randomBytes(16)
        let ciphertext = try cbcCrypt(key: keys.clientWriteKey, iv: iv, data: payload, encrypt: true)
        return iv + ciphertext
    }

    static func decryptRecord(keys: KeyBlock, fromServer: Bool, sequence: UInt64,
                              contentType: UInt8, encrypted: Data) throws -> Data {
        guard encrypted.count >= 16 else { throw TLSError.cryptoFailure("record too short") }
        let iv = encrypted.prefix(16)
        let ciphertext = encrypted.dropFirst(16)
        let readKey = fromServer ? keys.serverWriteKey : keys.clientWriteKey
        let macKey = fromServer ? keys.serverMacKey : keys.clientMacKey
        let decrypted = try cbcCrypt(key: readKey, iv: Data(iv), data: Data(ciphertext), encrypt: false)
        guard let padValue = decrypted.last else { throw TLSError.cryptoFailure("empty plaintext") }
        let contentLength = decrypted.count - (Int(padValue) + 1)
        guard contentLength >= keys.suite.macLength else {
            throw TLSError.cryptoFailure("plaintext too short for MAC")
        }
        let plaintext = decrypted.prefix(contentLength - keys.suite.macLength)
        let receivedMac = decrypted[(contentLength - keys.suite.macLength)..<contentLength]
        let expectedMac = computeMac(macKey: macKey, sequence: sequence,
                                     contentType: contentType, data: Data(plaintext),
                                     suite: keys.suite)
        guard Data(receivedMac) == expectedMac else { throw TLSError.macFailure }
        return Data(plaintext)
    }

    static func finishedVerifyData(master: Data, label: Data, transcript: Data,
                                   suite: Suite) -> Data {
        let hash: Data
        switch suite {
        case .aes128CbcSha: hash = Data(SHA256.hash(data: transcript))
        case .aes256CbcSha384: hash = Data(SHA384.hash(data: transcript))
        }
        return prf(secret: master, label: label, seed: hash, length: 12, suite: suite)
    }

    // MARK: - Framing helpers (pure)

    static func makeRecord(contentType: UInt8, payload: Data) -> Data {
        var out = Data([contentType, 0x03, 0x03])
        out.append(contentsOf: withBE16(UInt16(payload.count)))
        out.append(contentsOf: payload)
        return out
    }

    static func makeHandshake(type: UInt8, body: Data) -> Data {
        var out = Data([type])
        let length = UInt32(body.count)
        out.append(contentsOf: [UInt8((length >> 16) & 0xff),
                                UInt8((length >> 8) & 0xff),
                                UInt8(length & 0xff)])
        out.append(contentsOf: body)
        return out
    }

    static func withBE16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func withBE64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * (7 - $0))) & 0xff) }
    }

    static func alertName(_ description: UInt8) -> String {
        switch description {
        case 0: return "close_notify"
        case 10: return "unexpected_message"
        case 20: return "bad_record_mac"
        case 40: return "handshake_failure"
        case 47: return "illegal_parameter"
        case 70: return "protocol_version"
        case 71: return "insufficient_security"
        case 80: return "internal_error"
        default: return "unknown"
        }
    }
}

/// Live TLS-PSK session over a TCPStream. Sequence numbers follow idevice
/// exactly: seq 0 for our Finished, then 1, 2… for app data; server seq
/// counts every decrypted handshake record.
final class TLSPskSession {
    private let stream: any DataStream
    private let keys: TLSPsk.KeyBlock
    private var writeSequence: UInt64
    private var readSequence: UInt64

    private init(stream: any DataStream, keys: TLSPsk.KeyBlock,
                 writeSequence: UInt64, readSequence: UInt64) {
        self.stream = stream
        self.keys = keys
        self.writeSequence = writeSequence
        self.readSequence = readSequence
    }

    static func handshake(stream: any DataStream, psk: Data,
                          timeout: TimeInterval = 10) async throws -> TLSPskSession {
        let clientRandom = TLSPsk.randomBytes(32)
        var serverRandom = Data(count: 32)
        var selectedCipher: [UInt8] = [0, 0]
        var transcript = Data()

        // 1. ClientHello.
        var chBody = Data(TLSPsk.version)
        chBody.append(contentsOf: clientRandom)
        chBody.append(0x00) // session_id len = 0
        let suites = TLSPsk.Suite.offered.flatMap { $0 }
        chBody.append(contentsOf: TLSPsk.withBE16(UInt16(suites.count)))
        chBody.append(contentsOf: suites)
        chBody.append(contentsOf: [0x01, 0x00]) // compression: null
        let ch = TLSPsk.makeHandshake(type: TLSPsk.hsClientHello, body: chBody)
        transcript.append(contentsOf: ch)
        try await stream.write(TLSPsk.makeRecord(contentType: TLSPsk.ctHandshake, payload: ch),
                               timeout: timeout)

        // 2. ServerHello … ServerHelloDone.
        serverHelloLoop: while true {
            let (contentType, payload) = try await readRecord(stream: stream, timeout: timeout)
            if contentType == TLSPsk.ctAlert {
                throw TLSPsk.TLSError.alert(level: payload.first ?? 0,
                                            description: payload.dropFirst().first ?? 0)
            }
            guard contentType == TLSPsk.ctHandshake else {
                throw TLSPsk.TLSError.unexpectedRecord(contentType)
            }
            transcript.append(contentsOf: payload)
            for message in parseHandshakeMessages(payload) {
                if message.type == TLSPsk.hsServerHello, message.body.count >= 34 + 2 {
                    // body: version(2) + random(32) + sid_len(1) + sid + cipher(2).
                    serverRandom = Data(message.body[2..<34])
                    let sidLength = Int(message.body[34])
                    if message.body.count >= 35 + sidLength + 2 {
                        selectedCipher = Array(message.body[(35 + sidLength)..<(37 + sidLength)])
                    }
                }
            }
            if containsServerHelloDone(payload) {
                break serverHelloLoop
            }
        }

        // 3. Keys.
        guard let suite = TLSPsk.Suite.from(bytes: selectedCipher) else {
            throw TLSPsk.TLSError.unsupportedCipher(selectedCipher)
        }
        let master = TLSPsk.masterSecret(psk: psk, clientRandom: clientRandom,
                                         serverRandom: serverRandom, suite: suite)
        let keys = TLSPsk.keyBlock(master: master, clientRandom: clientRandom,
                                   serverRandom: serverRandom, suite: suite)

        // 4. ClientKeyExchange (empty PSK identity).
        let cke = TLSPsk.makeHandshake(type: TLSPsk.hsClientKeyExchange, body: Data([0x00, 0x00]))
        transcript.append(contentsOf: cke)
        try await stream.write(TLSPsk.makeRecord(contentType: TLSPsk.ctHandshake, payload: cke),
                               timeout: timeout)

        // 5. ChangeCipherSpec.
        try await stream.write(TLSPsk.makeRecord(contentType: TLSPsk.ctChangeCipherSpec,
                                                 payload: Data([0x01])), timeout: timeout)

        // 6. Client Finished (encrypted, seq 0).
        let verify = TLSPsk.finishedVerifyData(master: master, label: Data("client finished".utf8),
                                               transcript: transcript, suite: suite)
        let finished = TLSPsk.makeHandshake(type: TLSPsk.hsFinished, body: verify)
        transcript.append(contentsOf: finished)
        let encryptedFinished = try TLSPsk.encryptRecord(keys: keys, sequence: 0,
                                                         contentType: TLSPsk.ctHandshake,
                                                         plaintext: finished)
        try await stream.write(TLSPsk.makeRecord(contentType: TLSPsk.ctHandshake,
                                                 payload: encryptedFinished), timeout: timeout)

        // 7. Server ChangeCipherSpec + Finished.
        var serverSequence: UInt64 = 0
        serverLoop: while true {
            let (contentType, payload) = try await readRecord(stream: stream, timeout: timeout)
            if contentType == TLSPsk.ctAlert {
                throw TLSPsk.TLSError.alert(level: payload.first ?? 0,
                                            description: payload.dropFirst().first ?? 0)
            }
            switch contentType {
            case TLSPsk.ctChangeCipherSpec:
                break // acknowledged; keep waiting for Finished
            case TLSPsk.ctApplicationData, TLSPsk.ctHandshake:
                let plaintext = try TLSPsk.decryptRecord(keys: keys, fromServer: true,
                                                         sequence: serverSequence,
                                                         contentType: TLSPsk.ctHandshake,
                                                         encrypted: payload)
                serverSequence += 1
                if plaintext.count >= 4, plaintext[plaintext.startIndex] == TLSPsk.hsFinished {
                    let expected = TLSPsk.finishedVerifyData(
                        master: master, label: Data("server finished".utf8),
                        transcript: transcript, suite: suite)
                    if plaintext.dropFirst(4) != expected {
                        // Upstream continues with a warning here; do the same —
                        // identical behavior to the proven implementation.
                        AppLogger.net.warning("Server Finished verify_data mismatch (continuing)",
                                              event: "tls.handshake")
                    }
                    break serverLoop
                }
            default:
                throw TLSPsk.TLSError.unexpectedRecord(contentType)
            }
        }

        return TLSPskSession(stream: stream, keys: keys,
                             writeSequence: 1, readSequence: serverSequence)
    }

    func writeAppData(_ data: Data, timeout: TimeInterval = 10) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: TLSPsk.maxPlaintext, limitedBy: data.endIndex)
                ?? data.endIndex
            let chunk = data[offset..<end]
            let encrypted = try TLSPsk.encryptRecord(keys: keys, sequence: writeSequence,
                                                     contentType: TLSPsk.ctApplicationData,
                                                     plaintext: Data(chunk))
            writeSequence += 1
            try await stream.write(TLSPsk.makeRecord(contentType: TLSPsk.ctApplicationData,
                                                     payload: encrypted), timeout: timeout)
            offset = end
        }
    }

    func readAppData(timeout: TimeInterval = 10) async throws -> Data {
        let (contentType, payload) = try await Self.readRecord(stream: stream, timeout: timeout)
        guard contentType == TLSPsk.ctApplicationData else {
            throw TLSPsk.TLSError.unexpectedRecord(contentType)
        }
        let plaintext = try TLSPsk.decryptRecord(keys: keys, fromServer: true,
                                                 sequence: readSequence,
                                                 contentType: TLSPsk.ctApplicationData,
                                                 encrypted: payload)
        readSequence += 1
        return plaintext
    }

    // MARK: - Record I/O

    struct HandshakeMessage {
        let type: UInt8
        let body: Data
    }

    static func containsServerHelloDone(_ payload: Data) -> Bool {
        guard payload.count >= 4 else { return false }
        for i in 0...(payload.count - 4) {
            if payload[payload.startIndex + i] == TLSPsk.hsServerHelloDone,
               payload[payload.startIndex + i + 1] == 0x00,
               payload[payload.startIndex + i + 2] == 0x00,
               payload[payload.startIndex + i + 3] == 0x00 {
                return true
            }
        }
        return false
    }

    static func parseHandshakeMessages(_ payload: Data) -> [HandshakeMessage] {
        var out: [HandshakeMessage] = []
        var pos = payload.startIndex
        while payload.index(pos, offsetBy: 4, limitedBy: payload.endIndex) != nil {
            let type = payload[pos]
            let length = (Int(payload[pos + 1]) << 16) | (Int(payload[pos + 2]) << 8)
                | Int(payload[pos + 3])
            guard let end = payload.index(pos, offsetBy: 4 + length, limitedBy: payload.endIndex),
                  end <= payload.endIndex else { break }
            out.append(HandshakeMessage(type: type, body: Data(payload[(pos + 4)..<end])))
            pos = end
        }
        return out
    }

    static func readRecord(stream: any DataStream, timeout: TimeInterval) async throws -> (UInt8, Data) {
        let header = try await stream.readExactly(5, timeout: timeout)
        let contentType = header[header.startIndex]
        let length = (Int(header[header.startIndex + 3]) << 8)
            | Int(header[header.startIndex + 4])
        let payload = try await stream.readExactly(length, timeout: timeout)
        return (contentType, payload)
    }
}
