import Foundation

/// Swift wrapper around the ported GrappaHelper ObjC: mints an authentic
/// Grappa client token for AirTraffic sync (HostInfo/RequestingSync Grappa
/// field). Returns nil with a log line when unavailable — the sync flow
/// treats the token as optional, exactly like the proven implementation.
enum GrappaToken {
    /// Generates a token; logs rc/err on failure. On the simulator (no
    /// AirTraffic private frameworks) this gracefully returns nil.
    static func generate(version: UInt32 = 1, deviceType: UInt32 = 0,
                         protocolVersion: UInt32 = 1) -> Data? {
        var out = Data(count: 512)
        var outLen = 0
        var err = Data(count: 256)
        let rc: Int32 = out.withUnsafeMutableBytes { outPtr in
            err.withUnsafeMutableBytes { errPtr in
                ALGetGrappaToken(
                    version, deviceType, protocolVersion,
                    outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    512, &outLen,
                    errPtr.baseAddress?.assumingMemoryBound(to: CChar.self), 256)
            }
        }
        guard rc == 0, outLen > 0 else {
            let message = String(data: err.prefix(while: { $0 != 0 }), encoding: .utf8)
                ?? "rc=\(rc)"
            AppLogger.airLift.info("Grappa token unavailable (\(message))",
                                   event: "airlift.grappa")
            return nil
        }
        let token = out.prefix(outLen)
        AppLogger.airLift.info("Grappa token generated (\(token.count)B)",
                               event: "airlift.grappa")
        return Data(token)
    }
}
