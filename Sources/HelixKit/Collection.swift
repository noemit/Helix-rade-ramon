import Foundation

public struct Field: Identifiable, Hashable, Codable {
    /// Object id of the field icon.
    public let id: Int
    public var name: String
    /// Field number used as the key inside record data.
    public var fieldID: UInt16
    public var type: FieldType
    public var created: HelixDate?
    public var modified: HelixDate?

    public init(id: Int, name: String, fieldID: UInt16, type: FieldType, created: HelixDate? = nil, modified: HelixDate? = nil) {
        (self.id, self.name, self.fieldID, self.type, self.created, self.modified) = (id, name, fieldID, type, created, modified)
    }

    public var displayName: String { name.isEmpty ? "Field \(fieldID)" : name }
}

public struct IndexInfo: Hashable, Codable {
    public let number: UInt16
    public let flags: UInt16
    public let nodeSize: UInt16
    public let entryCount: UInt32
    public let root: UInt32
}

/// An icon placed in a collection or relation window (icon-mode position, top-left).
public struct IconPlacement: Hashable, Codable {
    public var objectID: Int
    public var v: Int
    public var h: Int

    public init(objectID: Int, v: Int, h: Int) {
        (self.objectID, self.v, self.h) = (objectID, v, h)
    }
}

public struct Relation: Identifiable, Hashable {
    public let id: Int
    public let name: String
    /// Identifier stamped on every record and index directory of this relation.
    public let dataID: UInt16
    /// Object ids of the icons on this relation's design window.
    public let iconIDs: [Int]
    public let icons: [IconPlacement]
    public let fields: [Field]
    public let indexes: [IndexInfo]

    public init(id: Int, name: String, dataID: UInt16, icons: [IconPlacement], fields: [Field], indexes: [IndexInfo]) {
        (self.id, self.name, self.dataID, self.icons, self.fields, self.indexes) = (id, name, dataID, icons, fields, indexes)
        iconIDs = icons.map(\.objectID)
    }

    /// The primary (record number) tree is index #1.
    public var recordTree: IndexInfo? { indexes.first { $0.number == 1 } }
    public var recordCount: Int { Int(recordTree?.entryCount ?? 0) }

    public func field(withID fid: UInt16) -> Field? { fields.first { $0.fieldID == fid } }
    public func field(objectID: Int) -> Field? { fields.first { $0.id == objectID } }
}

public struct Record: Identifiable, Hashable {
    public let id: UInt32
    public var values: [UInt16: Value]
    /// Per-value attribute word stored alongside each value (meaning not fully known).
    public var attributes: [UInt16: UInt16]

    public init(id: UInt32, values: [UInt16: Value], attributes: [UInt16: UInt16] = [:]) {
        self.id = id
        self.values = values
        self.attributes = attributes
    }

    public subscript(field: Field) -> Value? {
        get { values[field.fieldID] }
        set { values[field.fieldID] = newValue }
    }
}

/// A Helix collection opened read-only from its heap file.
public final class HelixCollection {
    public let heap: HeapFile
    public let objects: ObjectTable
    public let name: String
    public let relations: [Relation]
    /// Font family names referenced by index from template rectangles.
    public let fontTable: [String]
    /// Icons in the collection window (relations, users, sequences).
    public let icons: [IconPlacement]

    public convenience init(url: URL) throws {
        try self.init(heap: HeapFile(url: url))
    }

    public convenience init(data: Data) throws {
        try self.init(heap: HeapFile(data: data))
    }

    public init(heap: HeapFile) throws {
        let table = try ObjectTable(heap: heap)
        var directories: [UInt16: [IndexInfo]] = [:]
        for dir in table.objects(ofKind: .indexDirectory) {
            let (dataID, infos) = Self.parseIndexDirectory(heap, dir)
            directories[dataID] = infos
        }
        let collectionObject = table.objects(ofKind: .collection).first
        let fontRef = collectionObject.map { Int(heap.u32(heap.offset(ofBlock: $0.block) + 0x68) & 0x7FFF_FFFF) / 4 }
        fontTable = Self.parseFontTable(heap, fontRef.flatMap { table[$0] }.flatMap { $0.kind == .fontTable ? $0 : nil })
        self.heap = heap
        objects = table
        name = collectionObject?.name ?? "Untitled"
        icons = collectionObject.map { Self.parseIcons(heap, $0) } ?? []
        relations = table.objects(ofKind: .relation).map { obj in
            Self.parseRelation(heap, obj, objects: table, directories: directories)
        }
    }

    // MARK: Design parsing

    static func parseIndexDirectory(_ heap: HeapFile, _ obj: DesignObject) -> (UInt16, [IndexInfo]) {
        let o = heap.offset(ofBlock: obj.block)
        let dataID = heap.u16(o + 4)
        let count = Int(heap.u16(o + 6))
        var infos: [IndexInfo] = []
        for i in 0..<count where 8 + (i + 1) * 14 <= obj.length {
            let e = o + 8 + i * 14
            infos.append(IndexInfo(number: heap.u16(e), flags: heap.u16(e + 2), nodeSize: heap.u16(e + 4),
                                   entryCount: heap.u32(e + 6), root: heap.u32(e + 10)))
        }
        return (dataID, infos)
    }

    static func parseRelation(_ heap: HeapFile, _ obj: DesignObject, objects: ObjectTable,
                              directories: [UInt16: [IndexInfo]]) -> Relation {
        let o = heap.offset(ofBlock: obj.block)
        let dataID = heap.u16(o + 0x3A)
        let placements = parseIcons(heap, obj)
        let icons = placements.map(\.objectID)
        let fields = icons.compactMap { objects[$0] }
            .filter { $0.kind == .field }
            .map { parseField(heap, $0) }
            .sorted { $0.fieldID < $1.fieldID }
        return Relation(id: obj.id, name: obj.name, dataID: dataID, icons: placements,
                        fields: fields, indexes: directories[dataID] ?? [])
    }

    /// Icon lists in collection and relation objects: `u16 count` at `+0x92`, then
    /// `{u32 ref, i16 v, i16 h}` entries.
    static func parseIcons(_ heap: HeapFile, _ obj: DesignObject) -> [IconPlacement] {
        let o = heap.offset(ofBlock: obj.block)
        return (0..<Int(heap.u16(o + 0x92))).compactMap { i in
            let e = o + 0x94 + i * 8
            guard 0x94 + (i + 1) * 8 <= obj.length else { return nil }
            return IconPlacement(objectID: Int(heap.u32(e) & 0x7FFF_FFFF) / 4, v: Int(heap.i16(e + 4)), h: Int(heap.i16(e + 6)))
        }
    }

    static func parseField(_ heap: HeapFile, _ obj: DesignObject) -> Field {
        let o = heap.offset(ofBlock: obj.block)
        func stamp(_ at: Int) -> HelixDate? {
            let jd = heap.u32(o + at)
            return jd == 0 ? nil : HelixDate(julianDay: Int(jd), seconds: Int(heap.u32(o + at + 4)))
        }
        return Field(id: obj.id, name: obj.name, fieldID: heap.u16(o + 0x38),
                     type: FieldType(code: heap.u8(o + 0x3C)), created: stamp(0x28), modified: stamp(0x30))
    }

    /// Design objects placed on a relation's window, optionally filtered by kind.
    public func objects(in relation: Relation, kind: ObjectKind? = nil) -> [DesignObject] {
        relation.iconIDs.compactMap { objects[$0] }.filter { kind == nil || $0.kind == kind }
    }

    // MARK: Records

    /// Reads all records of a relation by walking its primary B-tree.
    public func records(of relation: Relation) throws -> [Record] {
        guard let tree = relation.recordTree, tree.root != 0 else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: relation.fields.map { ($0.fieldID, $0) })
        return try BTree(heap: heap, root: tree.root).entries().map { entry in
            try readRecord(atBlock: entry.value, dataID: relation.dataID, fields: byID)
        }
    }

    static let inlineLimit = 24

    func readRecord(atBlock block: UInt32, dataID: UInt16, fields: [UInt16: Field]) throws -> Record {
        guard heap.isValidBlock(block) else { throw HelixFormatError("Record block \(block) out of range.") }
        let o = heap.offset(ofBlock: block)
        guard heap.u16(o) == dataID else { throw HelixFormatError("Block \(block) is not a record of this relation.") }
        let recordID = heap.u32(o + 2)
        let end = o + Int(heap.u16(o + 8))
        guard end <= heap.bytes.count else { throw HelixFormatError("Record \(recordID) overruns file.") }

        var values: [UInt16: Value] = [:]
        var attributes: [UInt16: UInt16] = [:]
        var p = o + 14
        while p + 6 <= end {
            let fid = heap.u16(p), attr = heap.u16(p + 2)
            var len = Int(heap.u16(p + 4))
            p += 6
            let bytes: ArraySlice<UInt8>
            var utf8 = false
            if len == 0xFFFF {
                bytes = try heap.blob(atBlock: heap.u32(p))
                p += 4
            } else {
                if len == 0xFFFC {
                    len = Int(heap.u32(p))
                    p += 4
                    utf8 = true
                } else if len > 0xFFF0 {
                    throw HelixFormatError("Record \(recordID): unsupported length marker \(String(len, radix: 16)).")
                }
                if len > Self.inlineLimit {
                    bytes = try heap.blob(atBlock: heap.u32(p))
                    guard bytes.count == len else { throw HelixFormatError("Record \(recordID): blob length mismatch.") }
                    p += 4
                } else {
                    bytes = heap.slice(p, len)
                    p += len + (len & 1)
                }
            }
            values[fid] = Self.decode(bytes, utf8: utf8, type: fields[fid]?.type ?? .text)
            attributes[fid] = attr
        }
        guard p == end else { throw HelixFormatError("Record \(recordID) did not parse cleanly.") }
        return Record(id: recordID, values: values, attributes: attributes)
    }

    static func decode(_ bytes: ArraySlice<UInt8>, utf8: Bool, type: FieldType) -> Value {
        func be32(_ i: Int) -> UInt32 {
            let s = bytes.startIndex + i
            return UInt32(bytes[s]) << 24 | UInt32(bytes[s + 1]) << 16 | UInt32(bytes[s + 2]) << 8 | UInt32(bytes[s + 3])
        }
        switch type {
        case .number where bytes.count == 8:
            return .number(Double(bitPattern: UInt64(be32(0)) << 32 | UInt64(be32(4))))
        case .date where bytes.count == 8:
            return .date(HelixDate(julianDay: Int(be32(0)), seconds: Int(be32(4))))
        case .flag where bytes.count >= 1:
            return .flag(bytes.contains { $0 != 0 })
        case .picture:
            return .picture(Data(bytes))
        case .text, .unknown, .number, .date, .flag:
            return .text(utf8 ? TextDecoding.utf8(bytes) : TextDecoding.macRoman(bytes))
        }
    }
}
