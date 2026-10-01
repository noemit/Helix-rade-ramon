import Foundation

/// Rectangle in template (QuickDraw) coordinates: y grows downward, units are pixels.
public struct HelixRect: Hashable, Codable {
    public var top: Int, left: Int, bottom: Int, right: Int

    public init(top: Int, left: Int, bottom: Int, right: Int) {
        (self.top, self.left, self.bottom, self.right) = (top, left, bottom, right)
    }

    public var width: Int { right - left }
    public var height: Int { bottom - top }

    public func offsetBy(dx: Int = 0, dy: Int = 0) -> HelixRect {
        HelixRect(top: top + dy, left: left + dx, bottom: bottom + dy, right: right + dx)
    }

    public func union(_ o: HelixRect) -> HelixRect {
        HelixRect(top: min(top, o.top), left: min(left, o.left), bottom: max(bottom, o.bottom), right: max(right, o.right))
    }
}

public enum HelixAlignment: UInt8, Hashable, Codable, CaseIterable {
    case left = 0, center = 1, right = 2
}

public struct HelixFont: Hashable, Codable {
    /// Family name from the collection font table; nil means the system font.
    public var family: String?
    public var size: Int
    /// QuickDraw style bits: 1 bold, 2 italic, 4 underline.
    public var style: UInt8

    public init(family: String?, size: Int, style: UInt8) {
        (self.family, self.size, self.style) = (family, size, style)
    }

    public var bold: Bool { style & 1 != 0 }
    public var italic: Bool { style & 2 != 0 }
    public var underline: Bool { style & 4 != 0 }
}

/// Display format of a data rectangle (`+0x26` kind, `+0x27` flags, `+0x28` u16 decimals).
/// Flags seen: `0x40` fixed decimals, `0x80` currency (grouped, with the Mac's regional
/// currency symbol appended, e.g. "3.319Pts").
public struct NumberFormat: Hashable, Codable {
    public var kind: UInt8
    public var flags: UInt8
    public var decimals: Int

    public var isNumber: Bool { kind == 1 }
    public var currency: Bool { flags & 0x80 != 0 }
    public var grouping: Bool { currency }
    /// True when the rectangle asks for a specific number layout (otherwise "general").
    public var isCustom: Bool { isNumber && flags & 0xC0 != 0 }

    public init(kind: UInt8, flags: UInt8, decimals: Int) {
        (self.kind, self.flags, self.decimals) = (kind, flags, decimals)
    }

    public static let general = NumberFormat(kind: 0, flags: 0, decimals: 0)

    /// Formats a number the way Helix would, using `locale` for separators.
    public func string(_ n: Double, locale: Locale, currencySymbol: String) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        if isCustom {
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
        } else {
            f.maximumFractionDigits = 6
        }
        var s = f.string(from: NSNumber(value: n)) ?? String(n)
        if grouping {
            // Group every 3 digits even for 4-digit numbers (Helix did; ICU's Spanish rules don't).
            let sep = locale.groupingSeparator ?? ".", dec = locale.decimalSeparator ?? ","
            let parts = s.components(separatedBy: dec)
            var intPart = parts[0], sign = ""
            if intPart.hasPrefix("-") { sign = "-"; intPart.removeFirst() }
            var grouped = ""
            for (i, ch) in intPart.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { grouped.append(contentsOf: sep.reversed()) }
                grouped.append(ch)
            }
            s = sign + String(grouped.reversed()) + (parts.count > 1 ? dec + parts[1] : "")
        }
        return currency ? s + currencySymbol : s
    }
}

/// A rectangle placed on a template.
///
/// Common layout (big-endian): `+6` rect (top, left, bottom, right as i16),
/// `+0x10` u16 parent id×4, `+0x12` u16 tab order, `+0x14` justification,
/// `+0x1A` font size, `+0x1C` font-table index, `+0x1E` style bits.
/// Labels store `u32 length` + UTF-8 text at `+0x20`; data rectangles store
/// two `{u32 icon ref, i16, i16}` slots (field / abacus) at `+0x3C` and `+0x44`.
/// Groups (page and repeat rectangles) store `u16 count` at `+0x1C` followed by child refs.
/// Flags: `+4` bit 0x80 framed; `+5` bit 0x80 vertical scroll bar.
public struct TemplateElement: Identifiable, Hashable, Codable {
    public enum Content: Hashable, Codable {
        case label(String)
        /// A field and/or abacus. When both are present the abacus supplies the default value.
        case data(fieldObjectID: Int?, abacusObjectID: Int?)
        case repeatGroup([TemplateElement])
        case group([TemplateElement])
    }

    public var id: Int
    public var rect: HelixRect
    public var font: HelixFont
    public var alignment: HelixAlignment
    public var tabOrder: Int
    public var content: Content
    public var framed = false
    public var scrollsVertically = false
    public var format = NumberFormat.general

    public init(id: Int, rect: HelixRect, font: HelixFont, alignment: HelixAlignment, tabOrder: Int, content: Content,
                framed: Bool = false, scrollsVertically: Bool = false, format: NumberFormat = .general) {
        (self.id, self.rect, self.font, self.alignment, self.tabOrder, self.content) = (id, rect, font, alignment, tabOrder, content)
        (self.framed, self.scrollsVertically, self.format) = (framed, scrollsVertically, format)
    }
}

public struct Template: Identifiable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var page: HelixRect
    public var elements: [TemplateElement]

    public init(id: Int, name: String, page: HelixRect, elements: [TemplateElement]) {
        (self.id, self.name, self.page, self.elements) = (id, name, page, elements)
    }

    /// The repeat rectangle, if this is a list template.
    public var repeatElement: TemplateElement? {
        elements.first { if case .repeatGroup = $0.content { true } else { false } }
    }

    /// Field icons in the order Helix visits rectangles (tab order within each group).
    /// Helix maps imported columns to a view's fields in this order.
    public var fieldOrder: [Int] {
        var seen = Set<Int>()
        func walk(_ els: [TemplateElement]) -> [Int] {
            els.sorted { ($0.tabOrder, $0.rect.top, $0.rect.left) < ($1.tabOrder, $1.rect.top, $1.rect.left) }.flatMap { e -> [Int] in
                switch e.content {
                case .data(let fid?, _): seen.insert(fid).inserted ? [fid] : []
                case .group(let c), .repeatGroup(let c): walk(c)
                default: []
                }
            }
        }
        return walk(elements)
    }

    /// Bounding box of all content (templates often have a page larger than what is used).
    public var contentBounds: HelixRect {
        elements.map(\.rect).reduce(HelixRect(top: 0, left: 0, bottom: 0, right: 0)) { $0.union($1) }
    }
}

public struct ViewDefinition: Identifiable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var templateID: Int?
    public var queryID: Int?
    /// Index object ids (current, then default) used to order records.
    public var indexID: Int?
    public var defaultIndexID: Int?
    /// Saved window frame in screen coordinates.
    public var window: HelixRect

    public init(id: Int, name: String, templateID: Int?, queryID: Int?, indexID: Int?, defaultIndexID: Int?, window: HelixRect) {
        (self.id, self.name, self.templateID, self.queryID) = (id, name, templateID, queryID)
        (self.indexID, self.defaultIndexID, self.window) = (indexID, defaultIndexID, window)
    }
}

extension HelixCollection {
    /// Resolves an `id * 4` reference (top bit is a flag) to an object id.
    func ref(_ at: Int) -> Int? {
        let r = Int(heap.u32(at) & 0x7FFF_FFFF)
        guard r > 0, r % 4 == 0, objects[r / 4] != nil else { return nil }
        return r / 4
    }

    func rect(_ o: Int) -> HelixRect {
        HelixRect(top: Int(heap.i16(o)), left: Int(heap.i16(o + 2)), bottom: Int(heap.i16(o + 4)), right: Int(heap.i16(o + 6)))
    }

    static func parseFontTable(_ heap: HeapFile, _ obj: DesignObject?) -> [String] {
        guard let obj else { return [] }
        let o = heap.offset(ofBlock: obj.block)
        return (0..<Int(heap.u16(o + 4))).map { i in
            let s = o + 6 + Int(heap.u16(o + 6 + i * 2))
            return TextDecoding.name(heap.slice(s + 1, Int(heap.u8(s))))
        }
    }

    public func template(id: Int) -> Template? {
        guard let obj = objects[id], obj.kind == .template else { return nil }
        let o = heap.offset(ofBlock: obj.block)
        guard let rootID = ref(o + 0x4C), let root = objects[rootID], root.kind == .templateGroup else { return nil }
        var visited = Set<Int>()
        let elements = groupChildren(root, visited: &visited)
        return Template(id: id, name: obj.name, page: rect(heap.offset(ofBlock: root.block) + 6), elements: elements)
    }

    private func groupChildren(_ group: DesignObject, visited: inout Set<Int>) -> [TemplateElement] {
        let o = heap.offset(ofBlock: group.block)
        let count = Int(heap.u16(o + 0x1C))
        return (0..<count).compactMap { i in
            guard let cid = ref(o + 0x1E + i * 4), visited.insert(cid).inserted else { return nil }
            return element(cid, visited: &visited)
        }
    }

    private func element(_ id: Int, visited: inout Set<Int>) -> TemplateElement? {
        guard let obj = objects[id] else { return nil }
        let o = heap.offset(ofBlock: obj.block)
        let content: TemplateElement.Content
        switch obj.kind {
        case .templateLabel:
            let n = Int(heap.u32(o + 0x20))
            content = .label(n > 0 && 0x24 + n <= obj.length ? TextDecoding.utf8(heap.slice(o + 0x24, n)) : "")
        case .templateRectangle:
            var field: Int?, abacus: Int?
            for slot in [ref(o + 0x3C), ref(o + 0x44)].compactMap({ $0 }) {
                switch objects[slot]?.kind {
                case .field: field = field ?? slot
                case .abacus: abacus = abacus ?? slot
                default: break
                }
            }
            content = .data(fieldObjectID: field, abacusObjectID: abacus)
        case .templateGroup:
            let children = groupChildren(obj, visited: &visited)
            content = heap.u8(o + 4) == 0x0A ? .repeatGroup(children) : .group(children)
        default:
            return nil
        }
        let fontIndex = Int(heap.u16(o + 0x1C))
        let family = obj.kind == .templateGroup ? nil : fontTable.indices.contains(fontIndex) ? fontTable[fontIndex] : nil
        return TemplateElement(
            id: id, rect: rect(o + 6),
            font: HelixFont(family: family?.isEmpty == false ? family : nil, size: Int(heap.u16(o + 0x1A)),
                            style: obj.kind == .templateGroup ? 0 : heap.u8(o + 0x1E)),
            alignment: HelixAlignment(rawValue: heap.u8(o + 0x14)) ?? .left,
            tabOrder: Int(heap.u16(o + 0x12)), content: content,
            framed: obj.kind != .templateGroup && heap.u8(o + 4) & 0x80 != 0,
            scrollsVertically: obj.kind == .templateRectangle && heap.u8(o + 5) & 0x80 != 0,
            format: obj.kind == .templateRectangle
                ? NumberFormat(kind: heap.u8(o + 0x26), flags: heap.u8(o + 0x27), decimals: Int(heap.u16(o + 0x28))) : .general)
    }

    public func view(id: Int) -> ViewDefinition? {
        guard let obj = objects[id], obj.kind == .view else { return nil }
        let o = heap.offset(ofBlock: obj.block)
        func typed(_ at: Int, _ kinds: Set<ObjectKind>) -> Int? {
            ref(at).flatMap { objects[$0]?.kind.map(kinds.contains) == true ? $0 : nil }
        }
        return ViewDefinition(id: id, name: obj.name, templateID: typed(o + 0x4C, [.template]),
                              queryID: typed(o + 0x50, [.query, .abacus]),
                              indexID: typed(o + 0x54, [.index]), defaultIndexID: typed(o + 0x5C, [.index]),
                              window: rect(o + 6))
    }

    public func views(in relation: Relation) -> [ViewDefinition] {
        objects(in: relation, kind: .view).compactMap { view(id: $0.id) }
    }

    /// The B-tree number of an index icon (matches `IndexInfo.number`).
    public func indexNumber(ofIndexObject id: Int) -> UInt16? {
        guard let obj = objects[id], obj.kind == .index else { return nil }
        return heap.u16(heap.offset(ofBlock: obj.block) + 0x38)
    }

    /// Records in the order of an index icon's B-tree. Records missing from the
    /// index (e.g. empty keys) are appended in record-number order.
    public func records(of relation: Relation, orderedByIndex indexObjectID: Int?) throws -> [Record] {
        order(try records(of: relation), relation: relation, byIndex: indexObjectID)
    }

    /// Ordering keys (field or abacus object ids) of an index icon:
    /// `u16 count` at `+0x48`, then `{u32 ref, u16 flags}` entries.
    public func indexKeys(ofIndexObject id: Int) -> [Int] {
        guard let obj = objects[id], obj.kind == .index else { return [] }
        let o = heap.offset(ofBlock: obj.block)
        return (0..<Int(heap.u16(o + 0x48))).compactMap { ref(o + 0x4A + $0 * 6) }
    }

    /// Orders records by an index. Records unchanged since import keep the exact order of
    /// Helix's B-tree; `modified` records (edited or new) are inserted by comparing index keys.
    public func order(_ records: [Record], relation: Relation, byIndex indexObjectID: Int?,
                      modified: Set<UInt32> = [], keyValue: ((Record, Int) -> Value?)? = nil) -> [Record] {
        guard let id = indexObjectID else { return records }
        var rank: [UInt32: Int] = [:]
        if let number = indexNumber(ofIndexObject: id), let info = relation.indexes.first(where: { $0.number == number }),
           info.root != 0, let entries = try? BTree(heap: heap, root: info.root).entries() {
            for (i, e) in entries.enumerated() where rank[e.value] == nil { rank[e.value] = i }
        }
        let key: (Record, Int) -> Value? = keyValue ?? { r, k in relation.field(objectID: k).flatMap { r[$0] } }
        return RecordOrdering.order(records, rank: rank, keys: indexKeys(ofIndexObject: id), key: key, modified: modified)
    }
}
