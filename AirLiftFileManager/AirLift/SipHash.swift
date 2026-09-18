import Foundation

/// SipHash-2-4, standard reference algorithm (Aumasson–Bernstein).
/// Used to validate `_remotepairing._tcp` mDNS authTags exactly the way
/// idevice does: SipHash-2-4(key = 16-byte alt_irk, message = UTF-8 service
/// identifier). Pure and unit-tested against the reference vectors.
enum SipHash24 {
    static func hash(key0: UInt64, key1: UInt64, message: [UInt8]) -> UInt64 {
        var v0 = UInt64(0x736f6d6570736575) ^ key0
        var v1 = UInt64(0x646f72616e646f6d) ^ key1
        var v2 = UInt64(0x6c7967656e657261) ^ key0
        var v3 = UInt64(0x7465646279746573) ^ key1

        var offset = 0
        let count = message.count
        while offset + 8 <= count {
            let m = loadLE(message, at: offset)
            v3 ^= m
            sipRound(&v0, &v1, &v2, &v3)
            sipRound(&v0, &v1, &v2, &v3)
            v0 ^= m
            offset += 8
        }
        var last = UInt64(count & 0xff) << 56
        let remaining = count - offset
        for i in 0..<remaining {
            last |= UInt64(message[offset + i]) << (8 * i)
        }
        v3 ^= last
        sipRound(&v0, &v1, &v2, &v3)
        sipRound(&v0, &v1, &v2, &v3)
        v0 ^= last

        v2 ^= 0xff
        sipRound(&v0, &v1, &v2, &v3)
        sipRound(&v0, &v1, &v2, &v3)
        sipRound(&v0, &v1, &v2, &v3)
        sipRound(&v0, &v1, &v2, &v3)
        return v0 ^ v1 ^ v2 ^ v3
    }

    private static func loadLE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (8 * i)
        }
        return value
    }

    private static func rotl(_ x: UInt64, _ bits: Int) -> UInt64 {
        (x << bits) | (x >> (64 - bits))
    }

    private static func sipRound(_ v0: inout UInt64, _ v1: inout UInt64,
                                 _ v2: inout UInt64, _ v3: inout UInt64) {
        v0 = v0 &+ v1; v1 = rotl(v1, 13); v1 ^= v0; v0 = rotl(v0, 32)
        v2 = v2 &+ v3; v3 = rotl(v3, 16); v3 ^= v2
        v0 = v0 &+ v3; v3 = rotl(v3, 21); v3 ^= v0
        v2 = v2 &+ v1; v1 = rotl(v1, 17); v1 ^= v2; v2 = rotl(v2, 32)
    }
}

/// Remote-pairing authTag math, a direct port of idevice
/// `compute_auth_tag` / `validate_auth_tag` (peer_device.rs):
/// k0/k1 = little-endian halves of the 16-byte alt_irk, SipHash-2-4 over the
/// service identifier, tag = first 6 little-endian digest bytes, reversed.
/// The TXT `authTag` is standard-base64 of those 6 bytes.
enum RemotePairingAuth {
    /// Returns the 6-byte tag, or nil when alt_irk is not 16 bytes.
    static func computeAuthTag(altIrk: [UInt8], serviceIdentifier: String) -> [UInt8]? {
        guard altIrk.count == 16 else { return nil }
        let k0 = loadLE64(altIrk, at: 0)
        let k1 = loadLE64(altIrk, at: 8)
        let digest = SipHash24.hash(key0: k0, key1: k1,
                                    message: Array(serviceIdentifier.utf8))
        var output = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            output[i] = UInt8((digest >> (8 * i)) & 0xff)
        }
        // tag[i] = output[5 - i]
        return (0..<6).map { output[5 - $0] }
    }

    /// Validates a TXT-record authTag against the stored credential.
    static func validates(authTagBase64: String, altIrk: Data,
                          serviceIdentifier: String) -> Bool {
        guard let raw = Data(base64Encoded: authTagBase64),
              raw.count == 6,
              let expected = computeAuthTag(altIrk: Array(altIrk),
                                            serviceIdentifier: serviceIdentifier) else {
            return false
        }
        return raw.elementsEqual(expected)
    }

    private static func loadLE64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (8 * i)
        }
        return value
    }
}
