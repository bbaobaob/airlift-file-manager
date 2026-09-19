import Foundation

/// IPv6 + TCP codec for the CDTunnel packet layer (idevice Adapter role).
/// After the CDTunnel handshake the TLS stream carries raw IPv6 packets;
/// this module builds/parses them plus TCP segments (SYN/ACK/data/FIN/RST
/// with MSS option, window, RFC 1071 checksum over the IPv6 pseudo-header).
enum IPv6 {
    // MARK: - Addresses

    /// Parses "fd12::1", "::1", full form, embedded IPv4 ("::ffff:1.2.3.4").
    /// Returns 16 bytes or nil.
    static func parseAddress(_ string: String) -> [UInt8]? {
        var s = string
        // Strip zone id / brackets.
        if s.hasPrefix("[") {
            guard let end = s.firstIndex(of: "]") else { return nil }
            s = String(s[s.index(after: s.startIndex)..<end])
        }
        if let pct = s.firstIndex(of: "%") {
            s = String(s[..<pct])
        }
        // Expand embedded IPv4 tail.
        if s.contains(".") {
            guard let lastColon = s.lastIndex(of: ":") else { return nil }
            let head = String(s[..<lastColon])
            let tail = String(s[s.index(after: lastColon)...])
            let octets = tail.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return nil }
            let high = (UInt16(octets[0]) << 8) | UInt16(octets[1])
            let low = (UInt16(octets[2]) << 8) | UInt16(octets[3])
            s = head + String(format: ":%x:%x", high, low)
        }
        let halves = s.split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false)
        var groups: [UInt16] = []
        func parseGroups(_ part: Substring, into out: inout [UInt16]) -> Bool {
            if part.isEmpty { return true }
            for piece in part.split(separator: ":", omittingEmptySubsequences: false) {
                // Empty pieces (from ":::" or a leading ":") are invalid;
                // "::" compression is handled by the caller split only.
                guard !piece.isEmpty, let value = UInt16(piece, radix: 16) else {
                    return false
                }
                out.append(value)
            }
            return true
        }
        if halves.count == 2 {
            var head: [UInt16] = []
            var tail: [UInt16] = []
            guard parseGroups(halves[0], into: &head),
                  parseGroups(halves[1], into: &tail),
                  head.count + tail.count <= 8 else { return nil }
            groups = head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            guard parseGroups(s[...], into: &groups), groups.count == 8 else { return nil }
        }
        var out: [UInt8] = []
        for group in groups {
            out.append(UInt8((group >> 8) & 0xff))
            out.append(UInt8(group & 0xff))
        }
        return out
    }

    // MARK: - IPv6 packets

    /// Builds a 40-byte header + payload (no extension headers).
    static func buildPacket(src: [UInt8], dst: [UInt8], nextHeader: UInt8,
                            payload: Data) -> Data {
        precondition(src.count == 16 && dst.count == 16, "IPv6 addresses are 16 bytes")
        var out = Data()
        out.append(contentsOf: [0x60, 0x00, 0x00, 0x00]) // version 6, flow 0
        let length = UInt16(payload.count)
        out.append(contentsOf: [UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        out.append(contentsOf: [nextHeader, 64]) // hop limit 64
        out.append(contentsOf: src)
        out.append(contentsOf: dst)
        out.append(contentsOf: payload)
        return out
    }

    struct Packet {
        let src: [UInt8]
        let dst: [UInt8]
        let nextHeader: UInt8
        let payload: Data
    }

    static func parsePacket(_ data: Data) -> Packet? {
        guard data.count >= 40,
              (data[data.startIndex] >> 4) == 6 else { return nil }
        let length = (Int(data[data.startIndex + 4]) << 8)
            | Int(data[data.startIndex + 5])
        guard data.count >= 40 + length else { return nil }
        let base = data.startIndex
        return Packet(
            src: Array(data[(base + 8)..<(base + 24)]),
            dst: Array(data[(base + 24)..<(base + 40)]),
            nextHeader: data[base + 6],
            payload: Data(data[(base + 40)..<(base + 40 + length)]))
    }

    // MARK: - TCP

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let fin = Flags(rawValue: 0x01)
        static let syn = Flags(rawValue: 0x02)
        static let rst = Flags(rawValue: 0x04)
        static let psh = Flags(rawValue: 0x08)
        static let ack = Flags(rawValue: 0x10)
    }

    struct Segment {
        let srcPort: UInt16
        let dstPort: UInt16
        let sequence: UInt32
        let acknowledgement: UInt32
        let flags: Flags
        let window: UInt16
        let headerLength: Int
        /// Raw header bytes (for option parsing).
        let header: Data
        let payload: Data
    }

    /// Builds a TCP segment (20-byte header + optional MSS option).
    static func buildSegment(srcPort: UInt16, dstPort: UInt16,
                             sequence: UInt32, acknowledgement: UInt32,
                             flags: Flags, window: UInt16,
                             mss: UInt16? = nil, payload: Data = Data()) -> Data {
        var options = Data()
        if let mss {
            options.append(contentsOf: [0x02, 0x04,
                                        UInt8((mss >> 8) & 0xff), UInt8(mss & 0xff)])
        }
        var out = Data()
        out.append(contentsOf: [UInt8((srcPort >> 8) & 0xff), UInt8(srcPort & 0xff)])
        out.append(contentsOf: [UInt8((dstPort >> 8) & 0xff), UInt8(dstPort & 0xff)])
        for shift in [24, 16, 8, 0] {
            out.append(UInt8((sequence >> shift) & 0xff))
        }
        for shift in [24, 16, 8, 0] {
            out.append(UInt8((acknowledgement >> shift) & 0xff))
        }
        out.append(UInt8(((5 + options.count / 4) << 4) & 0xf0))
        out.append(flags.rawValue)
        out.append(contentsOf: [UInt8((window >> 8) & 0xff), UInt8(window & 0xff)])
        out.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        out.append(contentsOf: [0x00, 0x00]) // urgent pointer
        out.append(contentsOf: options)
        out.append(contentsOf: payload)
        return out
    }

    static func parseSegment(_ data: Data) -> Segment? {
        guard data.count >= 20 else { return nil }
        let base = data.startIndex
        func u16(_ offset: Int) -> UInt16 {
            (UInt16(data[base + offset]) << 8) | UInt16(data[base + offset + 1])
        }
        func u32(_ offset: Int) -> UInt32 {
            (UInt32(data[base + offset]) << 24) | (UInt32(data[base + offset + 1]) << 16)
                | (UInt32(data[base + offset + 2]) << 8) | UInt32(data[base + offset + 3])
        }
        let headerLength = Int((data[base + 12] >> 4) & 0x0f) * 4
        guard headerLength >= 20, data.count >= headerLength else { return nil }
        return Segment(srcPort: u16(0), dstPort: u16(2),
                       sequence: u32(4), acknowledgement: u32(8),
                       flags: Flags(rawValue: data[base + 13]),
                       window: u16(14),
                       headerLength: headerLength,
                       header: Data(data[base..<(base + headerLength)]),
                       payload: Data(data[(base + headerLength)...]))
    }

    /// RFC 1071 checksum over the IPv6 pseudo-header + segment (checksum
    /// field zeroed by the caller before invoking).
    static func tcpChecksum(src: [UInt8], dst: [UInt8], segment: Data) -> UInt16 {
        var sum: UInt32 = 0
        func fold(_ bytes: [UInt8]) {
            var i = 0
            while i < bytes.count {
                let high = UInt32(bytes[i]) << 8
                let low = i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0
                sum += high | low
                i += 2
            }
        }
        fold(src)
        fold(dst)
        let length = UInt32(segment.count)
        sum += (length >> 16) & 0xffff
        sum += length & 0xffff
        sum += 6 // next header: TCP
        fold(Array(segment))
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return UInt16(~sum & 0xffff)
    }

    /// Stamps the checksum into bytes 16–17 of a built segment.
    static func withChecksum(src: [UInt8], dst: [UInt8], segment: Data) -> Data {
        var out = segment
        let value = tcpChecksum(src: src, dst: dst, segment: segment)
        out[out.startIndex + 16] = UInt8((value >> 8) & 0xff)
        out[out.startIndex + 17] = UInt8(value & 0xff)
        return out
    }

    /// Parses a TCP MSS option value from raw header bytes, if present.
    static func parseMSS(_ header: Data) -> UInt16? {
        var i = 20
        while i + 1 < header.count {
            let kind = header[header.startIndex + i]
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < header.count else { break }
            let length = Int(header[header.startIndex + i + 1])
            guard length >= 2, i + length <= header.count else { break }
            if kind == 2, length == 4 {
                return (UInt16(header[header.startIndex + i + 2]) << 8)
                    | UInt16(header[header.startIndex + i + 3])
            }
            i += length
        }
        return nil
    }
}
