import CryptoKit
import Foundation

/// Minimal unsigned big integer (little-endian [UInt64] limbs) sufficient
/// for SRP-6a modpow on the 3072-bit group. Schoolbook multiply + Barrett
/// reduction (precomputed for N). Fully unit-tested against a Python oracle.
struct SRPBigUInt: Equatable {
    /// Little-endian limbs, normalized (no trailing zero limbs; empty = 0).
    var limbs: [UInt64]

    static let zero = SRPBigUInt(limbs: [])
    static let one = SRPBigUInt(limbs: [1])

    init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) {
        self.init(limbs: value == 0 ? [] : [value])
    }

    init(bytesBE: [UInt8]) {
        var limbs: [UInt64] = []
        var i = bytesBE.count
        while i > 0 {
            let start = max(0, i - 8)
            var limb: UInt64 = 0
            for j in start..<i {
                limb = (limb << 8) | UInt64(bytesBE[j])
            }
            limbs.append(limb)
            i = start
        }
        self.init(limbs: limbs)
    }

    init(bytesBE: Data) {
        self.init(bytesBE: Array(bytesBE))
    }

    /// Minimal big-endian bytes (empty for zero).
    var bytesBE: [UInt8] {
        var out: [UInt8] = []
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((limb >> shift) & 0xff))
            }
        }
        while out.count > 1 && out.first == 0 {
            out.removeFirst()
        }
        if out.allSatisfy({ $0 == 0 }) { return [] }
        return out
    }

    /// Big-endian bytes left-padded with zeros to `count`.
    func fixedBE(_ count: Int) -> [UInt8]? {
        let minimal = bytesBE
        guard minimal.count <= count else { return nil }
        return [UInt8](repeating: 0, count: count - minimal.count) + minimal
    }

    var isZero: Bool { limbs.isEmpty }
    var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
    }

    private mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }

    // MARK: - Compare

    static func < (lhs: SRPBigUInt, rhs: SRPBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
        }
        return false
    }

    // MARK: - Add / sub (a >= b for sub)

    static func + (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var out: [UInt64] = []
        out.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let a = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (s1, o1) = a.addingReportingOverflow(b)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out.append(s2)
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        if carry != 0 { out.append(carry) }
        return SRPBigUInt(limbs: out)
    }

    /// Requires lhs >= rhs.
    static func - (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        var out: [UInt64] = []
        out.reserveCapacity(lhs.limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<lhs.limbs.count {
            let a = lhs.limbs[i]
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (d1, o1) = a.subtractingReportingOverflow(b)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out.append(d2)
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return SRPBigUInt(limbs: out)
    }

    // MARK: - Multiply (schoolbook)

    static func * (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        if lhs.isZero || rhs.isZero { return .zero }
        var out = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.limbs.count {
                let (hi, lo) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (s1, o1) = out[i + j].addingReportingOverflow(lo)
                out[i + j] = s1
                var c = hi + (o1 ? 1 : 0)
                let (s2, o2) = out[i + j + 1].addingReportingOverflow(carry)
                out[i + j + 1] = s2
                c = (o2 ? 1 : 0)
                let (s3, o3) = out[i + j + 1].addingReportingOverflow(c)
                out[i + j + 1] = s3
                carry = c + (o3 ? 1 : 0)
            }
            var k = i + rhs.limbs.count
            while carry != 0 {
                let (s, o) = out[k].addingReportingOverflow(carry)
                out[k] = s
                carry = o ? 1 : 0
                k += 1
            }
        }
        return SRPBigUInt(limbs: out)
    }

    // MARK: - Shifts (bit-granular, for Barrett)

    func shiftedLeft(bits: Int) -> SRPBigUInt {
        if isZero || bits == 0 { return self }
        let limbShift = bits / 64
        let bitShift = bits % 64
        var out = [UInt64](repeating: 0, count: limbs.count + limbShift + (bitShift > 0 ? 1 : 0))
        var carry: UInt64 = 0
        for i in 0..<limbs.count {
            let low = bitShift == 0 ? limbs[i] : (limbs[i] << bitShift) | carry
            carry = bitShift == 0 ? 0 : limbs[i] >> (64 - bitShift)
            out[i + limbShift] = low
        }
        if bitShift > 0 { out[limbs.count + limbShift] = carry }
        return SRPBigUInt(limbs: out)
    }

    func shiftedRightLimbs(_ count: Int) -> SRPBigUInt {
        guard count < limbs.count else { return .zero }
        return SRPBigUInt(limbs: Array(limbs[count...]))
    }

    // MARK: - Modular arithmetic (Barrett, modulus fixed per call-site)

    /// Barrett reduction context for a fixed modulus.
    struct BarrettReducer {
        let modulus: SRPBigUInt
        let limbCount: Int
        let mu: SRPBigUInt

        init(modulus: SRPBigUInt) {
            self.modulus = modulus
            limbCount = modulus.limbs.count
            // mu = floor(2^(64*2*m) / N)
            let power = SRPBigUInt(limbs: [1]).shiftedLeft(bits: 64 * 2 * limbCount)
            mu = BarrettReducer.divide(power, modulus).quotient
        }

        func reduce(_ x: SRPBigUInt) -> SRPBigUInt {
            if x < modulus { return x }
            // Barrett: q1 = floor(x / B^(m-1)), q2 = q1*mu, q3 = floor(q2 / B^(m+1)).
            // Then q-2 <= q3 <= q, so prod = q3*N <= x and x - prod < 3N.
            let q1 = x.shiftedRightLimbs(limbCount - 1)
            let q2 = q1 * mu
            let q3 = q2.shiftedRightLimbs(limbCount + 1)
            var r = x - q3 * modulus
            var corrections = 0
            while !(r < modulus) && corrections < 4 {
                r = r - modulus
                corrections += 1
            }
            return r
        }

        /// Binary long division (only used to precompute mu once).
        static func divide(_ a: SRPBigUInt, _ b: SRPBigUInt) -> (quotient: SRPBigUInt, remainder: SRPBigUInt) {
            precondition(!b.isZero, "division by zero")
            if a < b { return (.zero, a) }
            var quotient = SRPBigUInt.zero
            var remainder = SRPBigUInt.zero
            for i in stride(from: a.bitLength - 1, through: 0, by: -1) {
                remainder = remainder + remainder
                if a.bit(at: i) { remainder = remainder + .one }
                if !(remainder < b) {
                    remainder = remainder - b
                    quotient = quotient + SRPBigUInt.one.shiftedLeft(bits: i)
                }
            }
            return (quotient, remainder)
        }
    }

    func bit(at index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> (index % 64)) & 1 == 1
    }

    var isOdd: Bool {
        guard let first = limbs.first else { return false }
        return first & 1 == 1
    }

    func shr1() -> SRPBigUInt {
        if isZero { return .zero }
        var out = [UInt64](repeating: 0, count: limbs.count)
        var carry: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let nextCarry = (limbs[i] & 1) << 63
            out[i] = (limbs[i] >> 1) | carry
            carry = nextCarry
        }
        return SRPBigUInt(limbs: out)
    }

    func modPow(_ exponent: SRPBigUInt, modulus: SRPBigUInt,
                reducer: BarrettReducer? = nil) -> SRPBigUInt {
        let red = reducer ?? BarrettReducer(modulus: modulus)
        var result = SRPBigUInt.one
        var base = red.reduce(self)
        var exp = exponent
        while !exp.isZero {
            if exp.isOdd {
                result = red.reduce(result * base)
            }
            exp = exp.shr1()
            base = red.reduce(base * base)
        }
        return result
    }

    func modMul(_ other: SRPBigUInt, modulus: SRPBigUInt,
                reducer: BarrettReducer? = nil) -> SRPBigUInt {
        let red = reducer ?? BarrettReducer(modulus: modulus)
        return red.reduce(self * other)
    }
}
