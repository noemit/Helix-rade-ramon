import Foundation

/// Kinds of design objects ("icons") found in the object table.
public enum ObjectKind: UInt8, CaseIterable {
    case collection = 2
    case relation = 3
    case field = 4
    case abacus = 5
    case template = 6
    case view = 7
    case index = 8
    case query = 9
    case user = 11
    case clipboard = 14
    /// Out-of-line name string referenced from another object's `+0x18` slot.
    case name = 15
    case operatorTile = 18
    case constantTile = 19
    /// Page and repeat rectangles: containers of other template rectangles.
    case templateGroup = 20
    case templateRectangle = 21
    case templateLabel = 22
    case menu = 31
    case indexDirectory = 39
    case fontTable = 45
    case idList = 54

    public var displayName: String {
        switch self {
        case .collection: "Collection"
        case .relation: "Relation"
        case .field: "Field"
        case .abacus: "Abacus"
        case .template: "Template"
        case .view: "View"
        case .index: "Index"
        case .query: "Query"
        case .user: "User"
        case .clipboard: "Clipboard"
        case .name: "Name"
        case .operatorTile: "Operator Tile"
        case .constantTile: "Constant Tile"
        case .templateGroup: "Template Group"
        case .templateRectangle: "Template Rectangle"
        case .templateLabel: "Template Label"
        case .menu: "Menu"
        case .indexDirectory: "Index Directory"
        case .fontTable: "Font Table"
        case .idList: "ID List"
        }
    }

    public var pluralName: String {
        switch self {
        case .abacus: "Abaci"
        case .query: "Queries"
        case .index: "Indexes"
        default: displayName + "s"
        }
    }
}

/// A live entry from the object table.
///
/// Every design object is a heap chunk starting with
/// `[u8 kind][u8 nameLength][u16 totalLength]`. Named objects store their
/// name in the last `nameLength` bytes of the chunk.
public struct DesignObject: Identifiable, Hashable {
    public let id: Int
    public let rawKind: UInt8
    public let block: UInt32
    public let length: Int
    public internal(set) var name: String

    public var kind: ObjectKind? { ObjectKind(rawValue: rawKind) }
}

/// The object table maps object ids to heap blocks. It is split into pages of
/// 256 `u32` entries; `0x60` in the top byte marks a live object and the low
/// 24 bits hold its block number. References between objects store `id * 4`.
public struct ObjectTable {
    public static let pageSize = 256
    public static let liveFlag: UInt32 = 0x60

    public let objects: [Int: DesignObject]

    public init(heap: HeapFile) throws {
        var objects: [Int: DesignObject] = [:]
        for (pageIndex, page) in try heap.objectTablePages().enumerated() {
            let base = heap.offset(ofBlock: page)
            for slot in 0..<Self.pageSize {
                let entry = heap.u32(base + slot * 4)
                guard entry >> 24 == Self.liveFlag else { continue }
                let block = entry & 0xFFFFFF
                guard heap.isValidBlock(block) else { continue }
                let id = pageIndex * Self.pageSize + slot
                let o = heap.offset(ofBlock: block)
                let kind = heap.u8(o)
                let nameLen = Int(heap.u8(o + 1))
                let length = Int(heap.u16(o + 2))
                var name = ""
                if nameLen > 0, nameLen < length, kind < 0x30 {
                    name = TextDecoding.name(heap.slice(o + length - nameLen, nameLen))
                }
                objects[id] = DesignObject(id: id, rawKind: kind, block: block, length: length, name: name)
            }
        }
        guard !objects.isEmpty else { throw HelixFormatError("Object table is empty.") }
        // Objects without an inline name reference a separate name object (id * 4 at +0x18).
        for (id, obj) in objects where obj.name.isEmpty && obj.rawKind < ObjectKind.operatorTile.rawValue {
            let ref = Int(heap.u32(heap.offset(ofBlock: obj.block) + 0x18))
            if ref > 0, ref % 4 == 0, let n = objects[ref / 4], n.kind == .name {
                objects[id]?.name = n.name
            }
        }
        self.objects = objects
    }

    public subscript(id: Int) -> DesignObject? { objects[id] }

    public func objects(ofKind kind: ObjectKind) -> [DesignObject] {
        objects.values.filter { $0.rawKind == kind.rawValue }.sorted { $0.id < $1.id }
    }
}
