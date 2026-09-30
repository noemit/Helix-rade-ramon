import Foundation

public struct HelixFormatError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// Low-level access to a "HeliX Heap" collection file.
///
/// The file is a heap of 32-byte blocks. Chunks are addressed by block number
/// (byte offset / 32) and all integers are big-endian.
public final class HeapFile {
    public static let signature = Array("HeliX Heap".utf8)
    public static let blockSize = 32

    public let bytes: [UInt8]

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 64, Array(bytes[0..<10]) == Self.signature else {
            throw HelixFormatError("Not a Helix collection (missing 'HeliX Heap' signature).")
        }
    }

    public var blockCount: Int { bytes.count / Self.blockSize }

    // MARK: Big-endian readers (out-of-range reads return 0; structural checks catch corruption)

    @inline(__always) public func u8(_ o: Int) -> UInt8 {
        o >= 0 && o < bytes.count ? bytes[o] : 0
    }

    @inline(__always) public func u16(_ o: Int) -> UInt16 {
        UInt16(u8(o)) << 8 | UInt16(u8(o + 1))
    }

    @inline(__always) public func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }

    @inline(__always) public func u24(_ o: Int) -> UInt32 {
        UInt32(u8(o)) << 16 | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2))
    }

    @inline(__always) public func u32(_ o: Int) -> UInt32 {
        UInt32(u16(o)) << 16 | UInt32(u16(o + 2))
    }

    public func f64(_ o: Int) -> Double {
        Double(bitPattern: UInt64(u32(o)) << 32 | UInt64(u32(o + 4)))
    }

    public func slice(_ o: Int, _ n: Int) -> ArraySlice<UInt8> {
        let lo = max(0, min(o, bytes.count)), hi = max(lo, min(o + n, bytes.count))
        return bytes[lo..<hi]
    }

    @inline(__always) public func offset(ofBlock b: UInt32) -> Int { Int(b) * Self.blockSize }

    public func isValidBlock(_ b: UInt32) -> Bool { b > 0 && Int(b) < blockCount }

    /// Reads a raw data chunk (`[0x00][u24 length][bytes]`) stored at `block`.
    public func blob(atBlock block: UInt32) throws -> ArraySlice<UInt8> {
        guard isValidBlock(block) else { throw HelixFormatError("Blob block \(block) out of range.") }
        let o = offset(ofBlock: block)
        guard u8(o) == 0 else { throw HelixFormatError("Block \(block) is not a data chunk.") }
        let len = Int(u24(o + 1))
        guard o + 4 + len <= bytes.count else { throw HelixFormatError("Blob at block \(block) overruns file.") }
        return bytes[(o + 4)..<(o + 4 + len)]
    }

    // MARK: Header

    /// Block number of the heap header (u32 at file offset 0x0A).
    public var headerBlock: UInt32 { u32(0x0A) }

    /// Object-table page blocks listed in the heap header.
    public func objectTablePages() throws -> [UInt32] {
        let h = offset(ofBlock: headerBlock)
        guard isValidBlock(headerBlock) else { throw HelixFormatError("Invalid heap header block.") }
        let count = Int(u16(h + 0x20))
        guard count > 0, count < 4096 else { throw HelixFormatError("Implausible object table page count \(count).") }
        let pages = (0..<count).map { u32(h + 0x22 + 4 * $0) }
        guard pages.allSatisfy(isValidBlock) else { throw HelixFormatError("Object table page out of range.") }
        return pages
    }
}

// MARK: Text decoding

enum TextDecoding {
    static func macRoman<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let data = Data(bytes)
        return String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }

    static func utf8<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let data = Data(bytes)
        return String(data: data, encoding: .utf8) ?? macRoman(data)
    }

    /// Design object names are UTF-8 in current collections; fall back to MacRoman for older ones.
    static func name<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let data = Data(bytes)
        return String(data: data, encoding: .utf8) ?? macRoman(data)
    }
}
