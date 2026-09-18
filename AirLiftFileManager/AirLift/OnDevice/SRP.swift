import CryptoKit
import Foundation

/// SRP-6a server-side math for pair-setup, matching idevice-srp with the
/// G_3072 group (RFC 5054 3072-bit prime, g=5) and SHA-512 throughout.
/// Direct port of `SrpServer`/`SrpClient::compute_verifier`/utils formulas.
/// All intermediate values unit-tested against an independent Python oracle.
enum SRP3072 {
    /// RFC 5054 3072-bit prime (same bytes as idevice-srp groups/3072.bin).
    static let nHex = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3be39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff"
    static let nLength = 384

    static var modulus: SRPBigUInt {
        SRPBigUInt(bytesBE: hexBytes(nHex))
    }

    static let generator = SRPBigUInt(5)
    static let username = Data("Pair-Setup".utf8)

    static func sha512(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// k = H(N || PAD(g)) with g left-padded to N length.
    static func k() -> SRPBigUInt {
        let nBytes = modulus.bytesBE
        let paddedLength = nBytes.count
        let gPadded = [UInt8](repeating: 0, count: paddedLength - 1) + [0x05]
        return SRPBigUInt(bytesBE: Array(sha512(Data(nBytes), Data(gPadded))))
    }

    /// x = H(salt || H(username || ":" || password)).
    static func x(salt: Data, password: Data) -> SRPBigUInt {
        let inner = sha512(username + Data(":".utf8) + password)
        return SRPBigUInt(bytesBE: Array(sha512(salt + inner)))
    }

    /// v = g^x % N (stored verifier).
    static func verifier(x: SRPBigUInt, reducer: SRPBigUInt.BarrettReducer? = nil) -> SRPBigUInt {
        generator.modPow(x, modulus: modulus, reducer: reducer)
    }

    /// B = (k*v + g^b) % N. Caller retries random b until B is 384 bytes.
    static func serverPublic(b: SRPBigUInt, v: SRPBigUInt, k: SRPBigUInt,
                             reducer: SRPBigUInt.BarrettReducer? = nil) -> SRPBigUInt {
        let red = reducer ?? SRPBigUInt.BarrettReducer(modulus: modulus)
        let term = red.reduce(k.modMul(v, modulus: modulus, reducer: red)
            + generator.modPow(b, modulus: modulus, reducer: red))
        return term
    }

    /// u = H(A_min || B_min) with minimal big-endian encodings.
    static func u(clientPublic A: SRPBigUInt, serverPublic B: SRPBigUInt) -> SRPBigUInt {
        SRPBigUInt(bytesBE: Array(sha512(Data(A.bytesBE), Data(B.bytesBE))))
    }

    /// S = (A * v^u)^b % N, then K = SHA512(S minimal BE).
    static func sessionKey(clientPublic A: SRPBigUInt, verifier v: SRPBigUInt,
                           u: SRPBigUInt, b: SRPBigUInt,
                           reducer: SRPBigUInt.BarrettReducer? = nil) -> Data {
        let red = reducer ?? SRPBigUInt.BarrettReducer(modulus: modulus)
        let base = red.reduce(A.modMul(v.modPow(u, modulus: modulus, reducer: red),
                                       modulus: modulus, reducer: red))
        let s = base.modPow(b, modulus: modulus, reducer: red)
        return sha512(Data(s.bytesBE))
    }

    static func padToN(_ value: SRPBigUInt) -> Data {
        Data(value.fixedBE(nLength) ?? [UInt8](repeating: 0, count: nLength))
    }

    /// M1 = H(H(N)^H(g) || H(username) || salt || PAD(A) || PAD(B) || K).
    static func m1(clientPublic A: SRPBigUInt, serverPublic B: SRPBigUInt,
                   key K: Data, salt: Data) -> Data {
        let nHash = sha512(Data(modulus.bytesBE))
        let gHash = sha512(Data([0x05]))
        let hng = Data(zip(nHash, gHash).map { $0 ^ $1 })
        return sha512(hng + sha512(username) + salt
            + padToN(A) + padToN(B) + K)
    }

    /// M2 = H(A_min || M1 || K).
    static func m2(clientPublic A: SRPBigUInt, m1: Data, key K: Data) -> Data {
        sha512(Data(A.bytesBE) + m1 + K)
    }

    // MARK: - Hex

    static func hexBytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var chars = hex.makeIterator()
        while let high = chars.next(), let low = chars.next() {
            out.append(UInt8(String([high, low]), radix: 16) ?? 0)
        }
        return out
    }
}
