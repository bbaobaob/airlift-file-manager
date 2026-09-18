import Foundation

/// Minimal unsigned big integer (little-endian [UInt64] limbs) sufficient
/// for SRP-6a modpow on the 3072-bit group. Hot loops use unsafe buffers
/// (bounds checks dominate in -Onone builds); schoolbook multiply +
/// Barrett reduction (precomputed per modulus). Fully unit-tested against
/// a Python oracle (add/mul/powmod + SRP K/M1/M2 goldens).
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
        out.reserveCapacity(limbs.count * 8)
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

    /// Big-endian bytes left-padded with zeros to `count` (nil if too big).
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
        return lhs.limbs.withUnsafeBufferPointer { x in
            rhs.limbs.withUnsafeBufferPointer { y in
                for i in stride(from: x.count - 1, through: 0, by: -1) {
                    if x[i] != y[i] { return x[i] < y[i] }
                }
                return false
            }
        }
    }

    // MARK: - Add / sub (sub requires lhs >= rhs)

    static func + (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        let n = max(lhs.limbs.count, rhs.limbs.count)
        var out = [UInt64](repeating: 0, count: n + 1)
        out.withUnsafeMutableBufferPointer { o in
            lhs.limbs.withUnsafeBufferPointer { x in
                rhs.limbs.withUnsafeBufferPointer { y in
                    var carry: UInt64 = 0
                    for i in 0..<n {
                        let a: UInt64 = i < x.count ? x[i] : 0
                        let b: UInt64 = i < y.count ? y[i] : 0
                        let (s1, c1) = a.addingReportingOverflow(b)
                        let (s2, c2) = s1.addingReportingOverflow(carry)
                        o[i] = s2
                        carry = (c1 ? 1 : 0) + (c2 ? 1 : 0)
                    }
                    o[n] = carry
                }
            }
        }
        return SRPBigUInt(limbs: out)
    }

    static func - (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        var out = [UInt64](repeating: 0, count: lhs.limbs.count)
        out.withUnsafeMutableBufferPointer { o in
            lhs.limbs.withUnsafeBufferPointer { x in
                rhs.limbs.withUnsafeBufferPointer { y in
                    var borrow: UInt64 = 0
                    for i in 0..<x.count {
                        let b: UInt64 = i < y.count ? y[i] : 0
                        let (d1, o1) = x[i].subtractingReportingOverflow(b)
                        let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                        o[i] = d2
                        borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                    }
                }
            }
        }
        return SRPBigUInt(limbs: out)
    }

    // MARK: - Multiply (schoolbook, 65-bit carry handled via spill)

    static func * (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        if lhs.isZero || rhs.isZero { return .zero }
        let n = lhs.limbs.count
        let m = rhs.limbs.count
        // +2 scratch limbs: the true product needs n+m; spill chains stay inside.
        var out = [UInt64](repeating: 0, count: n + m + 2)
        out.withUnsafeMutableBufferPointer { o in
            lhs.limbs.withUnsafeBufferPointer { x in
                rhs.limbs.withUnsafeBufferPointer { y in
                    for i in 0..<n {
                        var carry: UInt64 = 0
                        for j in 0..<m {
                            let k = i + j
                            let (hi, lo) = x[i].multipliedFullWidth(by: y[j])
                            let (s1, c1) = o[k].addingReportingOverflow(lo)
                            let (s2, c2) = s1.addingReportingOverflow(carry)
                            o[k] = s2
                            // new carry = hi + c1 + c2 (≤ 2^64+1): low part
                            // stays, at most 1 spills into o[k+1] right away.
                            let (c3, f1) = hi.addingReportingOverflow(c1 ? 1 : 0)
                            let (c4, f2) = c3.addingReportingOverflow(c2 ? 1 : 0)
                            carry = c4
                            if f1 || f2 {
                                var t = k + 1
                                var one: UInt64 = 1
                                while one != 0 {
                                    precondition(t < o.count, "mul spill overflow")
                                    let (s, oFlag) = o[t].addingReportingOverflow(one)
                                    o[t] = s
                                    one = oFlag ? 1 : 0
                                    t += 1
                                }
                            }
                        }
                        // Fold the remaining carry into o[i+m] (+spill chain).
                        var k = i + m
                        var c = carry
                        while c != 0 {
                            precondition(k < o.count, "mul carry overflow")
                            let (s, oFlag) = o[k].addingReportingOverflow(c)
                            o[k] = s
                            c = oFlag ? 1 : 0
                            k += 1
                        }
                    }
                }
            }
        }
        return SRPBigUInt(limbs: out)
    }

    // MARK: - Shifts

    func shiftedLeft(bits: Int) -> SRPBigUInt {
        if isZero || bits == 0 { return self }
        let limbShift = bits / 64
        let bitShift = bits % 64
        var out = [UInt64](repeating: 0, count: limbs.count + limbShift + (bitShift > 0 ? 1 : 0))
        out.withUnsafeMutableBufferPointer { o in
            limbs.withUnsafeBufferPointer { x in
                var carry: UInt64 = 0
                for i in 0..<x.count {
                    o[i + limbShift] = bitShift == 0 ? x[i] : (x[i] << bitShift) | carry
                    carry = bitShift == 0 ? 0 : x[i] >> (64 - bitShift)
                }
                if bitShift > 0 { o[x.count + limbShift] = carry }
            }
        }
        return SRPBigUInt(limbs: out)
    }

    func shr1() -> SRPBigUInt {
        if isZero { return .zero }
        var out = [UInt64](repeating: 0, count: limbs.count)
        out.withUnsafeMutableBufferPointer { o in
            limbs.withUnsafeBufferPointer { x in
                var carry: UInt64 = 0
                for i in stride(from: x.count - 1, through: 0, by: -1) {
                    let next = (x[i] & 1) << 63
                    o[i] = (x[i] >> 1) | carry
                    carry = next
                }
            }
        }
        return SRPBigUInt(limbs: out)
    }

    var isOdd: Bool {
        guard let first = limbs.first else { return false }
        return first & 1 == 1
    }

    func shiftedRightLimbs(_ count: Int) -> SRPBigUInt {
        guard count < limbs.count else { return .zero }
        return SRPBigUInt(limbs: Array(limbs[count...]))
    }

    func bit(at index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> (index % 64)) & 1 == 1
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
            // mu = floor(2^(64*2*m) / N), computed once via binary division.
            let power = SRPBigUInt(limbs: [1]).shiftedLeft(bits: 64 * 2 * limbCount)
            mu = BarrettReducer.divide(power, modulus).quotient
        }

        func reduce(_ x: SRPBigUInt) -> SRPBigUInt {
            if x < modulus { return x }
            // Barrett: q1 = floor(x / B^(m-1)); q2 = q1*mu;
            // q3 = floor(q2 / B^(m+1)); then q-2 <= q3 <= q, so
            // prod = q3*N <= x and x - prod < 3N: at most 3 corrections.
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
