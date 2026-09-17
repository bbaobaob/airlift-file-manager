import Foundation
import Compression

/// Minimal ZIP reader/writer in pure Swift (Apple Compression framework for DEFLATE).
/// Supports method 0 (stored) and method 8 (deflate), UTF-8 names, CRC-32 validation.
/// No third-party dependency required.
enum ZipArchive {

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c: UInt32 = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Public types

    struct EntryInfo: Identifiable, Equatable {
        let path: String
        let isDirectory: Bool
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        var id: String { path }
    }

    enum ZipError: LocalizedError {
        case notAZipFile
        case corrupt(String)
        case unsupportedMethod(UInt16)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .notAZipFile: return "File is not a ZIP archive"
            case .corrupt(let m): return "Corrupt archive: \(m)"
            case .unsupportedMethod(let m): return "Unsupported compression method \(m)"
            case .checksumMismatch(let n): return "Checksum mismatch for \(n)"
            }
        }
    }

    // MARK: - Writing

    /// Writes a zip containing the given items. Directories are walked recursively.
    static func write(entries: [URL], to archiveURL: URL) throws {
        var centralRecords: [Data] = []
        var body = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir) else {
                throw FileSystemError.notFound(entry.path)
            }
            if isDir.boolValue {
                let dirPath = entry.lastPathComponent + "/"
                appendStored(name: dirPath, data: Data(), isDirectory: true,
                             body: &body, offset: &offset, central: &centralRecords)
                if let enumerator = fileManager.enumerator(at: entry, includingPropertiesForKeys: nil) {
                    for case let child as URL in enumerator {
                        var childIsDir: ObjCBool = false
                        fileManager.fileExists(atPath: child.path, isDirectory: &childIsDir)
                        let prefix = entry.lastPathComponent + "/"
                        let relative = prefix + child.path.dropFirst(entry.path.count + 1)
                        if childIsDir.boolValue {
                            appendStored(name: relative + "/", data: Data(), isDirectory: true,
                                         body: &body, offset: &offset, central: &centralRecords)
                        } else {
                            let data = (try? Data(contentsOf: child)) ?? Data()
                            appendDeflated(name: relative, data: data,
                                           body: &body, offset: &offset, central: &centralRecords)
                        }
                    }
                }
            } else {
                let data = try Data(contentsOf: entry)
                appendDeflated(name: entry.lastPathComponent, data: data,
                               body: &body, offset: &offset, central: &centralRecords)
            }
        }

        let centralStart = offset
        var centralData = Data()
        for record in centralRecords { centralData.append(record) }
        let centralSize = UInt32(centralData.count)
        let eocd = endOfCentralDirectory(entryCount: UInt16(centralRecords.count),
                                         centralSize: centralSize,
                                         centralOffset: centralStart)

        var output = body
        output.append(centralData)
        output.append(eocd)
        try output.write(to: archiveURL, options: .atomic)
    }

    private static func appendStored(name: String, data: Data, isDirectory: Bool,
                                     body: inout Data, offset: inout UInt32,
                                     central: inout [Data]) {
        let crc = isDirectory ? 0 : crc32(data)
        let local = localHeader(name: name, method: 0, crc: crc,
                                compressedSize: UInt32(data.count),
                                uncompressedSize: UInt32(data.count),
                                needsDataDescriptor: false)
        body.append(local)
        body.append(data)
        central.append(centralRecord(name: name, method: 0, crc: crc,
                                     compressedSize: UInt32(data.count),
                                     uncompressedSize: UInt32(data.count),
                                     offset: offset))
        offset += UInt32(local.count + data.count)
    }

    private static func appendDeflated(name: String, data: Data,
                                       body: inout Data, offset: inout UInt32,
                                       central: inout [Data]) {
        let crc = crc32(data)
        let compressed = deflate(data) ?? data
        let method: UInt16 = compressed.count < data.count ? 8 : 0
        let payload = method == 8 ? compressed : data
        let local = localHeader(name: name, method: method, crc: crc,
                                compressedSize: UInt32(payload.count),
                                uncompressedSize: UInt32(data.count),
                                needsDataDescriptor: false)
        body.append(local)
        body.append(payload)
        central.append(centralRecord(name: name, method: method, crc: crc,
                                     compressedSize: UInt32(payload.count),
                                     uncompressedSize: UInt32(data.count),
                                     offset: offset))
        offset += UInt32(local.count + payload.count)
    }

    private static func localHeader(name: String, method: UInt16, crc: UInt32,
                                    compressedSize: UInt32, uncompressedSize: UInt32,
                                    needsDataDescriptor: Bool) -> Data {
        var d = Data()
        let nameData = name.data(using: .utf8) ?? Data()
        d.appendLE(UInt32(0x04034b50))
        d.appendLE(UInt16(20))          // version needed
        d.appendLE(UInt16(0x0800))      // UTF-8 flag
        d.appendLE(method)
        d.appendLE(UInt16(0))           // mod time
        d.appendLE(UInt16(0x5D5A))      // mod date (fixed)
        d.appendLE(crc)
        d.appendLE(needsDataDescriptor ? UInt32(0) : compressedSize)
        d.appendLE(needsDataDescriptor ? UInt32(0) : uncompressedSize)
        d.appendLE(UInt16(nameData.count))
        d.appendLE(UInt16(0))
        d.append(nameData)
        return d
    }

    private static func centralRecord(name: String, method: UInt16, crc: UInt32,
                                      compressedSize: UInt32, uncompressedSize: UInt32,
                                      offset: UInt32) -> Data {
        var d = Data()
        let nameData = name.data(using: .utf8) ?? Data()
        d.appendLE(UInt32(0x02014b50))
        d.appendLE(UInt16(20))          // version made by
        d.appendLE(UInt16(20))          // version needed
        d.appendLE(UInt16(0x0800))      // UTF-8 flag
        d.appendLE(method)
        d.appendLE(UInt16(0))
        d.appendLE(UInt16(0x5D5A))
        d.appendLE(crc)
        d.appendLE(compressedSize)
        d.appendLE(uncompressedSize)
        d.appendLE(UInt16(nameData.count))
        d.appendLE(UInt16(0))           // extra
        d.appendLE(UInt16(0))           // comment
        d.appendLE(UInt16(0))           // disk
        d.appendLE(UInt16(0))           // internal attrs
        d.appendLE(UInt32(0))           // external attrs
        d.appendLE(offset)
        d.append(nameData)
        return d
    }

    private static func endOfCentralDirectory(entryCount: UInt16, centralSize: UInt32,
                                              centralOffset: UInt32) -> Data {
        var d = Data()
        d.appendLE(UInt32(0x06054b50))
        d.appendLE(UInt16(0))
        d.appendLE(UInt16(0))
        d.appendLE(entryCount)
        d.appendLE(entryCount)
        d.appendLE(centralSize)
        d.appendLE(centralOffset)
        d.appendLE(UInt16(0))
        return d
    }

    // MARK: - Reading

    static func listEntries(in archiveURL: URL) throws -> [EntryInfo] {
        let data = try Data(contentsOf: archiveURL)
        let records = try centralDirectoryRecords(data: data)
        return records.map { record in
            EntryInfo(path: record.name,
                      isDirectory: record.name.hasSuffix("/"),
                      compressedSize: UInt64(record.compressedSize),
                      uncompressedSize: UInt64(record.uncompressedSize))
        }
    }

    static func extract(archiveURL: URL, to destinationDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: archiveURL)
        let records = try centralDirectoryRecords(data: data)

        for record in records {
            // Zip-slip guard: reject absolute paths and parent traversal.
            guard !record.name.hasPrefix("/"),
                  !record.name.contains("../"),
                  !record.name.contains("..\\") else {
                throw ZipError.corrupt("unsafe path \(record.name)")
            }
            let target = destinationDirectory.appendingPathComponent(record.name)
            if record.name.hasSuffix("/") {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard record.method == 0 || record.method == 8 else {
                throw ZipError.unsupportedMethod(record.method)
            }
            let lower = Int(record.localHeaderOffset)
            guard lower + 30 <= data.count else { throw ZipError.corrupt("bad offset") }
            let signature = data.readLE32(at: lower)
            guard signature == 0x04034b50 else { throw ZipError.corrupt("bad local header") }
            let nameLen = Int(data.readLE16(at: lower + 26))
            let extraLen = Int(data.readLE16(at: lower + 28))
            let dataStart = lower + 30 + nameLen + extraLen
            let dataEnd = dataStart + Int(record.compressedSize)
            guard dataEnd <= data.count else { throw ZipError.corrupt("truncated entry") }
            let payload = data.subdata(in: dataStart..<dataEnd)
            let content: Data
            switch record.method {
            case 0: content = payload
            case 8:
                guard let inflated = inflate(payload, expectedSize: Int(record.uncompressedSize)) else {
                    throw ZipError.corrupt(record.name)
                }
                content = inflated
            default: throw ZipError.unsupportedMethod(record.method)
            }
            guard crc32(content) == record.crc else {
                throw ZipError.checksumMismatch(record.name)
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try content.write(to: target, options: .atomic)
        }
    }

    private struct CDRecord {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private static func centralDirectoryRecords(data: Data) throws -> [CDRecord] {
        // Locate EOCD (scan last 64KB).
        let eocdSignature: UInt32 = 0x06054b50
        var eocdOffset = -1
        let scanStart = max(0, data.count - 66_000)
        var i = data.count - 22
        while i >= scanStart {
            if data.readLE32(at: i) == eocdSignature {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notAZipFile }
        let entryCount = Int(data.readLE16(at: eocdOffset + 10))
        let centralSize = Int(data.readLE32(at: eocdOffset + 12))
        let centralOffset = Int(data.readLE32(at: eocdOffset + 16))
        guard centralOffset + centralSize <= data.count else { throw ZipError.corrupt("bad central directory") }

        var records: [CDRecord] = []
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, data.readLE32(at: cursor) == 0x02014b50 else {
                throw ZipError.corrupt("bad central record")
            }
            let method = data.readLE16(at: cursor + 10)
            let crc = data.readLE32(at: cursor + 16)
            let compressedSize = data.readLE32(at: cursor + 20)
            let uncompressedSize = data.readLE32(at: cursor + 24)
            let nameLen = Int(data.readLE16(at: cursor + 28))
            let extraLen = Int(data.readLE16(at: cursor + 30))
            let commentLen = Int(data.readLE16(at: cursor + 32))
            let localOffset = data.readLE32(at: cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLen <= data.count else { throw ZipError.corrupt("bad name") }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            records.append(CDRecord(name: name, method: method, crc: crc,
                                    compressedSize: compressedSize,
                                    uncompressedSize: uncompressedSize,
                                    localHeaderOffset: localOffset))
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return records
    }

    // MARK: - Compression glue

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let destCapacity = data.count + 1024
        var destination = Data(count: destCapacity)
        let written = destination.withUnsafeMutableBytes { destPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_encode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!, destCapacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        destination.removeSubrange(written..<destination.count)
        return destination
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = max(expectedSize, data.count * 4, 64)
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { destPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_decode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written >= 0 else { return nil }
        destination.removeSubrange(written..<destination.count)
        return destination
    }
}

/// Little-endian helpers, also used by tests that craft synthetic archives.
extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }

    func readLE16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readLE32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
