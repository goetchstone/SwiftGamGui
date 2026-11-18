import GamEngine
import zlib

/// A ZIP read in memory, never extracted: Foundation has none, and a shelled `ditto` or `unzip` writes files. It reads
/// what Python's `zipfile` reads, as GamGUI's `roster.py` drives it (3.14's `zipfile`, read to the end of each function),
/// so a package GamGUI refuses is refused here, in its words:
///
/// - **The end record first** (`_EndRecData`, `_EndRecData64`), and a central directory past `CENTRAL_DIRECTORY_CAP` or
///   listing more than `MEMBERS_CAP` entries is refused before it is walked (`_refuse_a_huge_directory`).
/// - **The directory walked as `_RealGetContents` walks it**: by its size, each entry's signature, cp437 or UTF-8 names,
///   the Unicode Path extra field, a version past 6.3 or a malformed extra field refusing the whole ZIP.
/// - **A member is unpacked as `ZipExtFile` unpacks it**: the local header's signature and name checked against the
///   directory, overlapping entries refused, stored or deflate only (inflated by zlib's raw `inflate`, as Python's `zlib`,
///   streamed), the output cut at the directory's size, and its CRC-32 checked at the end. The caller counts every byte
///   as it comes out (`unpack`'s `cap`), in the 1 MiB reads GamGUI's `_bounded` makes.
///
/// Where this is stricter than `zipfile` (ZIP64, a NUL in a name, BZIP2 and LZMA members, entries sharing a header) it
/// refuses; `docs/domains/classroom.md` lists each.
struct RosterZip {
    struct Entry {
        /// The name `zipfile` gives it: cut at a NUL.
        let name: String
        /// The name as the directory spells it (`orig_filename`), which the local header must match.
        let original: String
        /// Its name held a NUL, which `zipfile` cuts at and this reader refuses.
        let hadNUL: Bool
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let size: UInt64
        let headerOffset: Int64
        let createSystem: UInt8
        let externalAttributes: UInt32
        /// Where the next entry's header (or the directory) starts: a member's data may not run past it.
        var endOffset: Int64 = 0

        var isFolder: Bool { name.utf8.last == UInt8(ascii: "/") }
    }

    let data: [UInt8]
    let entries: [Entry]

    static let notAZip = PackageError("That isn't a ZIP file. Choose the ZIP your SIS exported, or its CSV files.")
    static let zip64 = PackageError("The ZIP is in the ZIP64 format, which no roster export needs. Export the roster again, "
                                    + "or choose its CSV files.")

    // MARK: the end record

    struct EndRecord {
        var isZip64 = false
        var entries: UInt64
        var size: UInt64
        var offset: UInt64
        /// Where the end record (or the ZIP64 one) starts.
        var location: Int64
    }

    /// `_EndRecData`: the end record, from the archive's tail alone, or nil. Throws `notAZip` where `zipfile` raises.
    static func endRecord(_ data: [UInt8]) throws -> EndRecord? {
        let size = data.count
        guard size >= 22 else { return nil }
        let tail = size - 22
        if data.matches("PK\u{05}\u{06}", at: tail), data[size - 2] == 0, data[size - 1] == 0 {
            return try endRecord64(data, at: tail, unpack(data, at: tail))
        }
        let maxCommentStart = max(size - 65_535 - 22, 0)
        var start = size - 4
        while start >= maxCommentStart, !data.matches("PK\u{05}\u{06}", at: start) { start -= 1 }
        guard start >= maxCommentStart, start + 22 <= size else { return nil }
        return try endRecord64(data, at: start, unpack(data, at: start))
    }

    private static func unpack(_ data: [UInt8], at start: Int) -> EndRecord {
        EndRecord(entries: UInt64(data.u16(start + 10)), size: UInt64(data.u32(start + 12)),
                  offset: UInt64(data.u32(start + 16)), location: Int64(start))
    }

    /// `_EndRecData64`: the ZIP64 records before the end record, when its locator is there.
    private static func endRecord64(_ data: [UInt8], at endOffset: Int, _ record: EndRecord) throws -> EndRecord {
        var offset = endOffset - 20
        guard offset >= 0, data.matches("PK\u{06}\u{07}", at: offset) else { return record }
        let disk = data.u32(offset + 4), relative = data.u64(offset + 8), disks = data.u32(offset + 16)
        guard disk == 0, disks <= 1 else { throw notAZip }
        offset -= 56
        guard offset >= 0, relative <= UInt64(offset) else { throw notAZip }
        var at = Int(relative), extra = offset - Int(relative)
        guard at + 56 <= data.count else { throw notAZip }
        if !data.matches("PK\u{06}\u{06}", at: at), at != offset {
            at = offset
            extra = 0
        }
        guard data.matches("PK\u{06}\u{06}", at: at) else { throw notAZip }
        let recordSize = data.u64(at + 4), entries = data.u64(at + 32), size = data.u64(at + 40), start = data.u64(at + 48)
        let (end, overflow) = start.addingReportingOverflow(size)
        guard !overflow, end == relative, recordSize.addingReportingOverflow(12) == (UInt64(56 + extra), false) else {
            throw notAZip
        }
        return EndRecord(isZip64: true, entries: entries, size: size, offset: start, location: Int64(offset - extra))
    }

    // MARK: the directory

    /// The ZIP's directory, read as `zipfile` reads it, after the size check `_refuse_a_huge_directory` makes first.
    static func open(_ data: [UInt8], caps: RosterCaps) throws -> RosterZip {
        guard let record = try endRecord(data) else { throw notAZip }
        if record.size > UInt64(caps.centralDirectory) || record.entries > UInt64(caps.members) {
            throw PackageError("The ZIP lists far more entries than a roster export holds. Check it's the right file.")
        }
        if record.isZip64 { throw zip64 }
        let size = Int(record.size)
        let concat = record.location - Int64(size) - Int64(record.offset)
        let startDirectory = Int64(record.offset) + concat
        guard startDirectory >= 0 else { throw notAZip }
        let directory = startDirectory >= Int64(data.count) ? [] :
            Array(data[Int(startDirectory)..<min(Int(startDirectory) + size, data.count)])
        var entries: [Entry] = []
        var cursor = 0, total = 0
        func read(_ count: Int) -> ArraySlice<UInt8> {
            let start = min(cursor, directory.count), end = min(cursor + count, directory.count)
            cursor += count
            return directory[start..<end]
        }
        while total < size {
            guard cursor + 46 <= directory.count else { throw notAZip }
            let at = cursor
            guard directory.matches("PK\u{01}\u{02}", at: at) else { throw notAZip }
            let createSystem = directory[at + 5], extractVersion = directory[at + 6]
            let flags = directory.u16(at + 8), method = directory.u16(at + 10)
            let crc = directory.u32(at + 16), compressed = directory.u32(at + 20), size = directory.u32(at + 24)
            let nameLength = Int(directory.u16(at + 28)), extraLength = Int(directory.u16(at + 30))
            let commentLength = Int(directory.u16(at + 32)), external = directory.u32(at + 38)
            let headerOffset = directory.u32(at + 42)
            cursor += 46
            let rawName = read(nameLength)
            guard var name = decodeName(rawName, utf8: flags & 0x800 != 0) else { throw notAZip }
            let original = name
            var hadNUL = name.unicodeScalars.contains("\0")
            name = cutAtNUL(name)
            let extra = Array(read(extraLength))
            _ = read(commentLength)
            if extractVersion > 63 { throw notAZip }
            // The extra fields, as `_decodeExtra` reads them: a malformed one refuses the ZIP; a Unicode Path field whose
            // CRC matches the name gives the name `zipfile` uses. A ZIP64 field matters only with a full field (below).
            var rest = extra[...]
            while rest.count >= 4 {
                let start = rest.startIndex
                let kind = UInt16(rest[start]) | UInt16(rest[start + 1]) << 8
                let length = Int(UInt16(rest[start + 2]) | UInt16(rest[start + 3]) << 8)
                guard length + 4 <= rest.count else { throw notAZip }
                let field = rest[(start + 4)..<(start + 4 + length)]
                if kind == 0x7075 {
                    guard field.count >= 5 else { throw notAZip }
                    let version = field[field.startIndex]
                    let fieldCRC = Array(field[(field.startIndex + 1)..<(field.startIndex + 5)]).u32(0)
                    if version == 1, fieldCRC == CRC32.checksum(rawName) {
                        guard let unicode = UTF8Check.decode(field.dropFirst(5)) else { throw notAZip }
                        if !unicode.isEmpty {
                            hadNUL = hadNUL || unicode.unicodeScalars.contains("\0")
                            name = cutAtNUL(unicode)
                        }
                    }
                }
                rest = rest[(start + 4 + length)...]
            }
            if compressed == 0xFFFF_FFFF || size == 0xFFFF_FFFF || headerOffset == 0xFFFF_FFFF { throw zip64 }
            entries.append(Entry(name: name, original: original, hadNUL: hadNUL, flags: flags, method: method, crc: crc,
                                 compressedSize: UInt64(compressed), size: UInt64(size),
                                 headerOffset: Int64(headerOffset) + concat, createSystem: createSystem,
                                 externalAttributes: external))
            total += 46 + nameLength + extraLength + commentLength
        }
        // Each member's data may run only up to the next header (`_end_offset`), the last up to the directory.
        var end = startDirectory
        // Python's sort is stable: equal offsets keep the directory's order.
        let order = entries.indices.sorted { (entries[$0].headerOffset, $0) < (entries[$1].headerOffset, $1) }
        for index in order.reversed() {
            entries[index].endOffset = end
            end = entries[index].headerOffset
        }
        return RosterZip(data: data, entries: entries)
    }

    private static func cutAtNUL(_ name: String) -> String {
        guard let nul = name.unicodeScalars.firstIndex(of: "\0") else { return name }
        return String(name.unicodeScalars[..<nul])
    }

    /// A name as `zipfile` decodes it: UTF-8 (strict) when the entry says so, else cp437.
    static func decodeName<Bytes: Collection<UInt8>>(_ bytes: Bytes, utf8: Bool) -> String? {
        if utf8 { return UTF8Check.decode(bytes) }
        return PythonText.string(bytes.map { $0 < 0x80 ? Unicode.Scalar($0) : cp437High[Int($0) - 0x80] })
    }

    // MARK: a member

    /// One member's bytes, unpacked as `ZipExtFile` gives them to GamGUI's `_bounded`: read 1 MiB at a time, its CRC-32
    /// checked when its end is reached, and refused one read past `cap` whatever its header says. `capped` is the refusal
    /// past it; anything else that stops it is `broken`.
    func unpack(_ entry: Entry, cap: Int, capped: PackageError, broken: PackageError) throws -> [UInt8] {
        let header = entry.headerOffset
        guard header >= 0, header <= Int64(data.count) - 30, data.matches("PK\u{03}\u{04}", at: Int(header)) else { throw broken }
        let at = Int(header)
        let localFlags = data.u16(at + 6)
        let nameLength = Int(data.u16(at + 26)), extraLength = Int(data.u16(at + 28))
        let rawName = data[(at + 30)..<min(at + 30 + nameLength, data.count)]
        if entry.flags & 0x20 != 0 || entry.flags & 0x40 != 0 { throw broken }      // patched data, strong encryption
        guard let localName = Self.decodeName(rawName, utf8: localFlags & 0x800 != 0),
              ExactKey(localName) == ExactKey(entry.original)
        else { throw broken }
        let start = Int64(at + 30 + nameLength + extraLength)
        // Overlapping members are a known ZIP bomb; `zipfile` only warns when two share one header, which this refuses.
        guard start + Int64(entry.compressedSize) <= entry.endOffset, start <= Int64(data.count) else { throw broken }
        guard entry.method == 0 || entry.method == 8 else { throw broken }
        let region = Int(start)..<min(Int(start) + Int(entry.compressedSize), data.count)
        return try data.withUnsafeBufferPointer { buffer throws -> [UInt8] in
            var source = MemberSource(buffer: UnsafeBufferPointer(rebasing: buffer[region]), deflated: entry.method == 8)
            defer { source.close() }
            var out: [UInt8] = []
            var left = entry.size, checksum = CRC32(), ended = false
            let unit = 1 << 20
            while true {
                var read = 0
                while read < unit, !ended {
                    var chunk = try source.next(max: unit - read, broken: broken)
                    if UInt64(chunk.count) > left { chunk.removeLast(chunk.count - Int(left)) }
                    left -= UInt64(chunk.count)
                    if left == 0 || source.finished { ended = true }
                    checksum.update(chunk)
                    if ended, checksum.value != entry.crc { throw broken }
                    out += chunk
                    read += chunk.count
                }
                if read == 0 { return out }
                if out.count > cap { throw capped }
            }
        }
    }

    /// Where a member's bytes come from: the stored bytes themselves, or the raw DEFLATE stream inflated as it's asked for.
    ///
    /// Inflated by zlib's own `inflate` (windowBits -15), the decoder Python's `zlib.decompressobj(-15)` wraps, so a stream
    /// `zipfile` refuses with `zlib.error` is refused here and one it reads to a short end is read the same way. The
    /// Compression framework's `COMPRESSION_ZLIB` can't be told apart that way: it consumes a corrupt stream whole and
    /// reports it as a truncated one, an error or a quiet nothing (docs/domains/classroom.md).
    private struct MemberSource {
        let buffer: UnsafeBufferPointer<UInt8>
        let deflated: Bool
        private var offset = 0
        private var stream: UnsafeMutablePointer<z_stream>?
        private(set) var finished = false

        init(buffer: UnsafeBufferPointer<UInt8>, deflated: Bool) {
            self.buffer = buffer
            self.deflated = deflated
        }

        mutating func next(max: Int, broken: PackageError) throws -> [UInt8] {
            guard !finished else { return [] }
            if !deflated {
                let end = Swift.min(offset + max, buffer.count)
                defer {
                    offset = end
                    if offset >= buffer.count { finished = true }
                }
                return Array(buffer[offset..<end])
            }
            if stream == nil {
                // z_stream points back at itself once initialised (zlib checks it), so it lives on the heap.
                let made = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
                made.initialize(to: z_stream())
                guard inflateInit2_(made, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    made.deallocate()
                    throw broken
                }
                made.pointee.next_in = UnsafeMutablePointer(mutating: buffer.baseAddress)
                made.pointee.avail_in = UInt32(buffer.count)
                stream = made
            }
            guard let stream else { throw broken }
            // Room for the rest of the 1 MiB read, as `decompress(data, n)` gives zlib: a smaller buffer can stop exactly at
            // the header's size and never reach garbage after it that `zipfile` inflates into and refuses.
            var out = [UInt8](repeating: 0, count: max)
            let status = out.withUnsafeMutableBufferPointer { destination in
                stream.pointee.next_out = destination.baseAddress
                stream.pointee.avail_out = UInt32(destination.count)
                return inflate(stream, Z_NO_FLUSH)
            }
            out.removeLast(Int(stream.pointee.avail_out))
            switch status {
            case Z_STREAM_END:
                finished = true
            case Z_OK:
                break
            case Z_BUF_ERROR where stream.pointee.avail_in == 0:
                // The input ran out before the stream's end: `zipfile` ends there too (its `flush` lets Z_BUF_ERROR
                // pass), and the CRC decides.
                finished = true
            default:
                // Z_DATA_ERROR and the rest: `zlib.error`, which GamGUI turns into "couldn't be unpacked".
                throw broken
            }
            return out
        }

        mutating func close() {
            if let stream {
                inflateEnd(stream)
                stream.deinitialize(count: 1)
                stream.deallocate()
            }
            stream = nil
        }
    }

    /// Code page 437's characters for 0x80…0xFF, as Python's `cp437` codec decodes them.
    static let cp437High: [Unicode.Scalar] = Array(
        ("ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
            + "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{A0}").unicodeScalars)
}

/// CRC-32 (ISO 3309, as ZIP and `zlib.crc32` compute it).
struct CRC32 {
    private(set) var value: UInt32 = 0

    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    mutating func update<Bytes: Sequence<UInt8>>(_ bytes: Bytes) {
        var crc = ~value
        for byte in bytes { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        value = ~crc
    }

    static func checksum<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }
}

extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }

    /// The four ASCII bytes of `signature` at `at`.
    func matches(_ signature: String, at: Int) -> Bool {
        let bytes = Array(signature.utf8)
        guard at >= 0, at + bytes.count <= count else { return false }
        return self[at..<(at + bytes.count)].elementsEqual(bytes)
    }
}
