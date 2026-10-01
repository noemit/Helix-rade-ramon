import Foundation

// MARK: Native, editable design

public struct QueryDesign: Identifiable, Hashable, Codable {
    public var id: Int
    public var name: String
    /// The abacus that selects records (true = include).
    public var abacusID: Int?
}

public struct IndexDesign: Identifiable, Hashable, Codable {
    public var id: Int
    public var name: String
    /// Ordering keys: field or abacus ids, most significant first.
    public var keys: [Int]
    /// Number of the matching B-tree in the Helix file while the keys are unchanged
    /// (gives Helix's exact order); nil for new or edited indexes.
    public var helixNumber: UInt16?
}

/// Icons Faulix shows but does not edit (users, sequences…).
public struct OtherIcon: Identifiable, Hashable, Codable {
    public var id: Int
    public var kind: UInt8
    public var name: String
}

public struct RelationDesign: Identifiable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var dataID: UInt16
    public var fields: [Field] = []
    /// Icons shown in the relation window (abaci that belong to queries are not shown).
    public var icons: [IconPlacement] = []
    public var abaci: [Abacus] = []
    public var templates: [Template] = []
    public var views: [ViewDefinition] = []
    public var queries: [QueryDesign] = []
    public var indexes: [IndexDesign] = []
    /// B-tree roots from the Helix file.
    public var helixIndexes: [IndexInfo] = []
}

/// The whole design of a collection, stored as JSON in the record store. Imported once from
/// the Helix file, then edited in Design mode.
public struct DesignModel: Hashable, Codable {
    public var name: String
    public var icons: [IconPlacement]
    public var relations: [RelationDesign]
    public var others: [OtherIcon]
    public var fontTable: [String]
    public var nextID: Int

    public init(importing c: HelixCollection) {
        name = c.name
        fontTable = c.fontTable
        icons = c.icons
        others = c.icons.compactMap { p in
            guard let o = c.objects[p.objectID], o.kind != .relation else { return nil }
            return OtherIcon(id: o.id, kind: o.rawKind, name: o.name)
        }
        nextID = max((c.objects.objects.keys.max() ?? 0) + 1, 100_000)
        relations = c.relations.map { rel in
            var r = RelationDesign(id: rel.id, name: rel.name, dataID: rel.dataID)
            r.fields = rel.fields
            r.icons = rel.icons.filter { c.objects[$0.objectID] != nil }
            r.helixIndexes = rel.indexes
            let iconObjects = rel.icons.compactMap { c.objects[$0.objectID] }
            func ids(_ k: ObjectKind) -> [Int] { iconObjects.filter { $0.kind == k }.map(\.id) }
            r.views = ids(.view).compactMap(c.view(id:))
            r.queries = ids(.query).map { QueryDesign(id: $0, name: c.objects[$0]?.name ?? "", abacusID: c.queryAbacusID(ofQuery: $0)) }
            r.indexes = ids(.index).map {
                IndexDesign(id: $0, name: c.objects[$0]?.name ?? "", keys: c.indexKeys(ofIndexObject: $0), helixNumber: c.indexNumber(ofIndexObject: $0))
            }
            var templateIDs = ids(.template)
            for v in r.views { if let t = v.templateID, !templateIDs.contains(t) { templateIDs.append(t) } }
            r.templates = templateIDs.compactMap(c.template(id:))
            // Abaci: icons, plus those used by queries, views, templates, indexes and other abaci.
            var pending = ids(.abacus) + r.queries.compactMap(\.abacusID) + r.views.compactMap(\.queryID)
                + r.indexes.flatMap(\.keys)
                + r.templates.flatMap { TemplateElement.flatten($0.elements) }.compactMap {
                    if case .data(_, let a) = $0.content { a } else { nil }
                }
            var seen = Set<Int>()
            while let id = pending.popLast() {
                guard seen.insert(id).inserted, c.objects[id]?.kind == .abacus, let a = c.abacus(id: id) else { continue }
                r.abaci.append(a)
                pending += a.root?.references ?? []
            }
            r.abaci.sort { $0.id < $1.id }
            return r
        }
    }
}

extension TemplateElement {
    public static func flatten(_ els: [TemplateElement]) -> [TemplateElement] {
        els.flatMap { e -> [TemplateElement] in
            switch e.content {
            case .group(let c), .repeatGroup(let c): flatten(c)
            default: [e]
            }
        }
    }
}

// MARK: Runtime access

/// The live, editable design. All lookups the app makes (names, kinds, templates, views,
/// abaci, queries, indexes) go through here.
public final class Design {
    public private(set) var model: DesignModel
    /// The Helix file, for B-tree orders of unchanged indexes.
    public let collection: HelixCollection?
    public private(set) var relations: [Relation] = []

    private var names: [Int: String] = [:]
    private var kinds: [Int: ObjectKind] = [:]
    private var owner: [Int: Int] = [:]

    public init(model: DesignModel, collection: HelixCollection?) {
        self.model = model
        self.collection = collection
        rebuild()
    }

    public var name: String { model.name }
    public var fontTable: [String] { model.fontTable }

    /// Applies an edit and refreshes lookups.
    public func update<T>(_ change: (inout DesignModel) throws -> T) rethrows -> T {
        let result = try change(&model)
        rebuild()
        return result
    }

    /// Replaces the whole model (undo).
    public func replace(with m: DesignModel) {
        model = m
        rebuild()
    }

    private func rebuild() {
        names = [:]; kinds = [:]; owner = [:]
        for o in model.others { names[o.id] = o.name; kinds[o.id] = ObjectKind(rawValue: o.kind) }
        relations = model.relations.map { r in
            names[r.id] = r.name; kinds[r.id] = .relation
            func reg(_ id: Int, _ n: String, _ k: ObjectKind) { names[id] = n; kinds[id] = k; owner[id] = r.id }
            r.fields.forEach { reg($0.id, $0.name, .field) }
            r.abaci.forEach { reg($0.id, $0.name, .abacus) }
            r.templates.forEach { reg($0.id, $0.name, .template) }
            r.views.forEach { reg($0.id, $0.name, .view) }
            r.queries.forEach { reg($0.id, $0.name, .query) }
            r.indexes.forEach { reg($0.id, $0.name, .index) }
            return Relation(id: r.id, name: r.name, dataID: r.dataID, icons: r.icons,
                            fields: r.fields.sorted { $0.fieldID < $1.fieldID }, indexes: r.helixIndexes)
        }
    }

    // MARK: Lookups

    public func name(of id: Int) -> String? { names[id] }
    public func kind(of id: Int) -> ObjectKind? { kinds[id] }
    public func relation(id: Int) -> Relation? { relations.first { $0.id == id } }
    public func relationDesign(id: Int) -> RelationDesign? { model.relations.first { $0.id == id } }
    public func relation(containing id: Int) -> Relation? { owner[id].flatMap(relation(id:)) }

    private func item<T: Identifiable>(_ id: Int, _ path: KeyPath<RelationDesign, [T]>) -> T? where T.ID == Int {
        guard let r = owner[id], let rd = relationDesign(id: r) else { return nil }
        return rd[keyPath: path].first { $0.id == id }
    }

    public func template(id: Int) -> Template? { item(id, \.templates) }
    public func view(id: Int) -> ViewDefinition? { item(id, \.views) }
    public func abacus(id: Int) -> Abacus? { item(id, \.abaci) }
    public func query(id: Int) -> QueryDesign? { item(id, \.queries) }
    public func index(id: Int) -> IndexDesign? { item(id, \.indexes) }
    public func field(id: Int) -> Field? { item(id, \.fields) }

    public func queryAbacusID(ofQuery id: Int) -> Int? { query(id: id)?.abacusID }
    public func indexKeys(ofIndexObject id: Int) -> [Int] { index(id: id)?.keys ?? [] }

    public func views(in relation: Relation) -> [ViewDefinition] { relationDesign(id: relation.id)?.views ?? [] }

    /// Icons placed in a relation window, optionally of one kind.
    public func icons(in relation: Relation, kind: ObjectKind? = nil) -> [Int] {
        relation.icons.map(\.objectID).filter { kinds[$0] != nil && (kind == nil || kinds[$0] == kind) }
    }

    /// All abaci of a relation (including those used only by queries), by name.
    public func abaci(in relation: Relation) -> [Abacus] {
        (relationDesign(id: relation.id)?.abaci ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func formulaText(_ tile: Tile?) -> String { Formula.print(tile) { [names] in names[$0] } }

    /// Parses formula text in the scope of a relation.
    public func parseFormula(_ text: String, in relation: Relation) throws -> Tile {
        let rd = relationDesign(id: relation.id)
        return try Formula.parse(text, field: { n in rd?.fields.first { $0.name == n }?.id },
                                 abacus: { n in rd?.abaci.first { $0.name == n }?.id },
                                 newTileID: { Int.random(in: 1_000_000_000...(Int.max / 2)) })
    }

    // MARK: Ordering

    /// Orders records by an index: Helix's exact B-tree order while the index is unchanged
    /// (edited/new records slotted in by key), otherwise by comparing key values.
    public func order(_ records: [Record], relation: Relation, byIndex indexID: Int?, modified: Set<UInt32> = [],
                      keyValue: ((Record, Int) -> Value?)? = nil) -> [Record] {
        guard let indexID, let idx = index(id: indexID) else { return records }
        var rank: [UInt32: Int] = [:]
        if let number = idx.helixNumber, let collection, let info = relation.indexes.first(where: { $0.number == number }),
           info.root != 0, let entries = try? BTree(heap: collection.heap, root: info.root).entries() {
            for (i, e) in entries.enumerated() where rank[e.value] == nil { rank[e.value] = i }
        }
        let key = keyValue ?? { r, k in relation.field(objectID: k).flatMap { r[$0] } }
        return RecordOrdering.order(records, rank: rank, keys: idx.keys, key: key, modified: modified)
    }
}

enum RecordOrdering {
    static func order(_ records: [Record], rank: [UInt32: Int], keys: [Int], key: (Record, Int) -> Value?,
                      modified: Set<UInt32>) -> [Record] {
        func less(_ a: Record, _ b: Record) -> Bool {
            for k in keys {
                let x = key(a, k), y = key(b, k)
                if x == y { continue }
                return Value.sortLess(x, y)
            }
            return a.id < b.id
        }
        if rank.isEmpty { return keys.isEmpty ? records : records.sorted(by: less) }
        var ordered = records.filter { !modified.contains($0.id) && rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        let rest = records.filter { modified.contains($0.id) || rank[$0.id] == nil }
        for r in rest where modified.contains(r.id) {
            var lo = 0, hi = ordered.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if less(ordered[mid], r) { lo = mid + 1 } else { hi = mid }
            }
            ordered.insert(r, at: lo)
        }
        return ordered + rest.filter { !modified.contains($0.id) }
    }
}

// MARK: Editing

extension DesignModel {
    public mutating func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    func relationIndex(_ id: Int) -> Int? { relations.firstIndex { $0.id == id } }

    /// Relation index owning an object id.
    func ownerIndex(_ id: Int) -> Int? {
        relations.firstIndex { r in
            r.fields.contains { $0.id == id } || r.abaci.contains { $0.id == id } || r.templates.contains { $0.id == id }
                || r.views.contains { $0.id == id } || r.queries.contains { $0.id == id } || r.indexes.contains { $0.id == id }
        }
    }

    /// A free icon position below the existing icons.
    static func freeSpot(_ icons: [IconPlacement]) -> (v: Int, h: Int) {
        guard let maxV = icons.map(\.v).max() else { return (20, 20) }
        let minH = icons.map(\.h).min() ?? 20
        let lastRow = icons.filter { $0.v > maxV - 40 }
        let h = (lastRow.map(\.h).max() ?? minH) + 100
        return h > minH + 900 ? (maxV + 70, minH) : (lastRow.map(\.v).min() ?? maxV, h)
    }

    mutating func addIcon(_ id: Int, to r: Int) {
        let p = Self.freeSpot(relations[r].icons)
        relations[r].icons.append(IconPlacement(objectID: id, v: p.v, h: p.h))
    }

    @discardableResult
    public mutating func addRelation(name: String) -> Int {
        let id = allocateID()
        let dataID = UInt16(min(Int(UInt16.max), (relations.map { Int($0.dataID) }.max() ?? 0) + 1))
        relations.append(RelationDesign(id: id, name: name, dataID: dataID))
        let p = Self.freeSpot(icons)
        icons.append(IconPlacement(objectID: id, v: p.v, h: p.h))
        return id
    }

    @discardableResult
    public mutating func addField(to relationID: Int, name: String, type: FieldType) -> Int? {
        guard let r = relationIndex(relationID) else { return nil }
        let id = allocateID()
        let fid = UInt16((relations[r].fields.map { Int($0.fieldID) }.max() ?? 0) + 1)
        relations[r].fields.append(Field(id: id, name: name, fieldID: fid, type: type))
        addIcon(id, to: r)
        return id
    }

    @discardableResult
    public mutating func addAbacus(to relationID: Int, name: String, root: Tile?, showIcon: Bool = true) -> Int? {
        guard let r = relationIndex(relationID) else { return nil }
        let id = allocateID()
        relations[r].abaci.append(Abacus(id: id, name: name, root: root))
        if showIcon { addIcon(id, to: r) }
        return id
    }

    /// A query with its own (hidden) abacus that selects every record until edited.
    @discardableResult
    public mutating func addQuery(to relationID: Int, name: String) -> Int? {
        guard let r = relationIndex(relationID),
              let aid = addAbacus(to: relationID, name: "", root: .constant(.flag(true)), showIcon: false) else { return nil }
        let id = allocateID()
        relations[r].queries.append(QueryDesign(id: id, name: name, abacusID: aid))
        addIcon(id, to: r)
        return id
    }

    @discardableResult
    public mutating func addIndex(to relationID: Int, name: String, keys: [Int]) -> Int? {
        guard let r = relationIndex(relationID) else { return nil }
        let id = allocateID()
        relations[r].indexes.append(IndexDesign(id: id, name: name, keys: keys, helixNumber: nil))
        addIcon(id, to: r)
        return id
    }

    @discardableResult
    public mutating func addView(to relationID: Int, name: String, templateID: Int?) -> Int? {
        guard let r = relationIndex(relationID) else { return nil }
        let id = allocateID()
        relations[r].views.append(ViewDefinition(id: id, name: name, templateID: templateID, queryID: nil, indexID: nil,
                                                 defaultIndexID: nil, window: HelixRect(top: 60, left: 60, bottom: 760, right: 1260)))
        addIcon(id, to: r)
        return id
    }

    /// A new template. With `fields`, lays out a label and a data rectangle per field
    /// (one per line for a form; one column each in a repeat row for a list).
    @discardableResult
    public mutating func addTemplate(to relationID: Int, name: String, fields: [Field] = [], list: Bool = false) -> Int? {
        guard let r = relationIndex(relationID) else { return nil }
        let id = allocateID()
        var els: [TemplateElement] = []
        let labelFont = HelixFont(family: "Palatino", size: 14, style: 1)
        let dataFont = HelixFont(family: "Lucida Grande", size: 13, style: 0)
        if list {
            var x = 8, rows: [TemplateElement] = []
            for f in fields {
                let w = f.type == .text ? 200 : 100
                els.append(TemplateElement(id: allocateID(), rect: HelixRect(top: 6, left: x, bottom: 28, right: x + w),
                                           font: labelFont, alignment: .left, tabOrder: els.count, content: .label(f.displayName)))
                rows.append(TemplateElement(id: allocateID(), rect: HelixRect(top: 38, left: x, bottom: 60, right: x + w),
                                            font: dataFont, alignment: .left, tabOrder: rows.count,
                                            content: .data(fieldObjectID: f.id, abacusObjectID: nil)))
                x += w + 6
            }
            els.append(TemplateElement(id: allocateID(), rect: HelixRect(top: 34, left: 4, bottom: 64, right: max(x, 200)),
                                       font: dataFont, alignment: .left, tabOrder: els.count, content: .repeatGroup(rows)))
        } else {
            for (i, f) in fields.enumerated() {
                let y = 12 + i * 30
                let h = f.type == .picture ? 80 : 22
                els.append(TemplateElement(id: allocateID(), rect: HelixRect(top: y, left: 10, bottom: y + 22, right: 160),
                                           font: labelFont, alignment: .left, tabOrder: 2 * i, content: .label(f.displayName + ":")))
                els.append(TemplateElement(id: allocateID(), rect: HelixRect(top: y, left: 170, bottom: y + h, right: 620),
                                           font: dataFont, alignment: .left, tabOrder: 2 * i + 1,
                                           content: .data(fieldObjectID: f.id, abacusObjectID: nil)))
            }
        }
        relations[r].templates.append(Template(id: id, name: name, page: HelixRect(top: 0, left: 0, bottom: 1100, right: 850), elements: els))
        addIcon(id, to: r)
        return id
    }

    public mutating func rename(_ id: Int, to name: String) {
        if let i = relationIndex(id) { relations[i].name = name; return }
        guard let r = ownerIndex(id) else { return }
        if let i = relations[r].fields.firstIndex(where: { $0.id == id }) { relations[r].fields[i].name = name }
        if let i = relations[r].abaci.firstIndex(where: { $0.id == id }) { relations[r].abaci[i].name = name }
        if let i = relations[r].templates.firstIndex(where: { $0.id == id }) { relations[r].templates[i].name = name }
        if let i = relations[r].views.firstIndex(where: { $0.id == id }) { relations[r].views[i].name = name }
        if let i = relations[r].queries.firstIndex(where: { $0.id == id }) { relations[r].queries[i].name = name }
        if let i = relations[r].indexes.firstIndex(where: { $0.id == id }) { relations[r].indexes[i].name = name }
    }

    /// Removes an object and its icon. References to it elsewhere become empty slots.
    public mutating func delete(_ id: Int) {
        if let i = relationIndex(id) {
            relations.remove(at: i)
            icons.removeAll { $0.objectID == id }
            return
        }
        guard let r = ownerIndex(id) else { return }
        relations[r].fields.removeAll { $0.id == id }
        relations[r].abaci.removeAll { $0.id == id }
        relations[r].templates.removeAll { $0.id == id }
        relations[r].views.removeAll { $0.id == id }
        if let q = relations[r].queries.first(where: { $0.id == id }), let a = q.abacusID,
           !relations[r].icons.contains(where: { $0.objectID == a }) {
            relations[r].abaci.removeAll { $0.id == a }
        }
        relations[r].queries.removeAll { $0.id == id }
        relations[r].indexes.removeAll { $0.id == id }
        relations[r].icons.removeAll { $0.objectID == id }
    }

    /// Copies a template, view, abacus, query or index; returns the new id.
    @discardableResult
    public mutating func duplicate(_ id: Int) -> Int? {
        guard let r = ownerIndex(id) else { return nil }
        let new = allocateID()
        let rel = relations[r]
        if var t = rel.templates.first(where: { $0.id == id }) {
            func renumber(_ els: [TemplateElement]) -> [TemplateElement] {
                els.map { e in
                    var e = e
                    e.id = allocateID()
                    if case .repeatGroup(let c) = e.content { e.content = .repeatGroup(renumber(c)) }
                    if case .group(let c) = e.content { e.content = .group(renumber(c)) }
                    return e
                }
            }
            t.id = new; t.name += " copy"; t.elements = renumber(t.elements)
            relations[r].templates.append(t)
        } else if var v = rel.views.first(where: { $0.id == id }) {
            v.id = new; v.name += " copy"; relations[r].views.append(v)
        } else if var a = rel.abaci.first(where: { $0.id == id }) {
            a.id = new; a.name += " copy"; relations[r].abaci.append(a)
        } else if var q = rel.queries.first(where: { $0.id == id }) {
            if let aid = q.abacusID, let a = rel.abaci.first(where: { $0.id == aid }) {
                let copy = allocateID()
                relations[r].abaci.append(Abacus(id: copy, name: a.name, root: a.root))
                q.abacusID = copy
            }
            q.id = new; q.name += " copy"; relations[r].queries.append(q)
        } else if var x = rel.indexes.first(where: { $0.id == id }) {
            x.id = new; x.name += " copy"; relations[r].indexes.append(x)
        } else {
            return nil
        }
        addIcon(new, to: r)
        return new
    }

    public mutating func moveIcon(_ id: Int, inRelation relationID: Int?, v: Int, h: Int) {
        if let rid = relationID, let r = relationIndex(rid), let i = relations[r].icons.firstIndex(where: { $0.objectID == id }) {
            relations[r].icons[i].v = v; relations[r].icons[i].h = h
        } else if relationID == nil, let i = icons.firstIndex(where: { $0.objectID == id }) {
            icons[i].v = v; icons[i].h = h
        }
    }

    public mutating func setField(_ f: Field) {
        guard let r = ownerIndex(f.id), let i = relations[r].fields.firstIndex(where: { $0.id == f.id }) else { return }
        relations[r].fields[i] = f
    }

    public mutating func setAbacus(_ a: Abacus) {
        guard let r = ownerIndex(a.id), let i = relations[r].abaci.firstIndex(where: { $0.id == a.id }) else { return }
        relations[r].abaci[i] = a
    }

    public mutating func setTemplate(_ t: Template) {
        guard let r = ownerIndex(t.id), let i = relations[r].templates.firstIndex(where: { $0.id == t.id }) else { return }
        relations[r].templates[i] = t
    }

    public mutating func setView(_ v: ViewDefinition) {
        guard let r = ownerIndex(v.id), let i = relations[r].views.firstIndex(where: { $0.id == v.id }) else { return }
        relations[r].views[i] = v
    }

    public mutating func setQuery(_ q: QueryDesign) {
        guard let r = ownerIndex(q.id), let i = relations[r].queries.firstIndex(where: { $0.id == q.id }) else { return }
        relations[r].queries[i] = q
    }

    public mutating func setIndex(_ x: IndexDesign) {
        guard let r = ownerIndex(x.id), let i = relations[r].indexes.firstIndex(where: { $0.id == x.id }) else { return }
        var x = x
        if x.keys != relations[r].indexes[i].keys { x.helixNumber = nil }
        relations[r].indexes[i] = x
    }
}

// MARK: Template editing

extension Template {
    public func element(_ id: Int) -> TemplateElement? {
        TemplateElement.flatten(elements).first { $0.id == id } ?? elements.first { $0.id == id }
            ?? repeatElement.flatMap { $0.id == id ? $0 : nil }
    }

    private static func map(_ els: [TemplateElement], _ f: (TemplateElement) -> TemplateElement?) -> [TemplateElement] {
        els.compactMap { e -> TemplateElement? in
            guard var e = f(e) else { return nil }
            switch e.content {
            case .repeatGroup(let c): e.content = .repeatGroup(map(c, f))
            case .group(let c): e.content = .group(map(c, f))
            default: break
            }
            return e
        }
    }

    public mutating func update(_ id: Int, _ change: (inout TemplateElement) -> Void) {
        elements = Self.map(elements) { e in
            guard e.id == id else { return e }
            var e = e
            change(&e)
            return e
        }
    }

    public mutating func remove(_ id: Int) {
        elements = Self.map(elements) { $0.id == id ? nil : $0 }
    }

    /// Adds an element: inside the repeat rectangle if its centre is in it, else on the page.
    public mutating func insert(_ e: TemplateElement) {
        if case .repeatGroup = e.content { elements.append(e); return }
        if let rep = repeatElement, case .repeatGroup(var kids) = rep.content,
           (rep.rect.left...rep.rect.right).contains((e.rect.left + e.rect.right) / 2),
           (rep.rect.top...rep.rect.bottom).contains((e.rect.top + e.rect.bottom) / 2) {
            kids.append(e)
            update(rep.id) { $0.content = .repeatGroup(kids) }
        } else {
            elements.append(e)
        }
    }

    /// Moves an element by a delta (a repeat rectangle carries its contents) and re-files it
    /// inside or outside the repeat rectangle.
    public mutating func move(_ id: Int, dx: Int, dy: Int) {
        guard var e = element(id) else { return }
        if case .repeatGroup(let kids) = e.content {
            e.rect = e.rect.offsetBy(dx: dx, dy: dy)
            e.content = .repeatGroup(kids.map { var k = $0; k.rect = k.rect.offsetBy(dx: dx, dy: dy); return k })
            let moved = e
            update(id) { $0 = moved }
            return
        }
        remove(id)
        e.rect = e.rect.offsetBy(dx: dx, dy: dy)
        insert(e)
    }

    /// Adds a repeat rectangle below the existing content, turning a form into a list.
    public mutating func makeList(id: Int) {
        guard repeatElement == nil else { return }
        let b = contentBounds
        let top = b.bottom + 10
        elements.append(TemplateElement(id: id, rect: HelixRect(top: top, left: 4, bottom: top + 34, right: max(b.right, 400)),
                                        font: HelixFont(family: nil, size: 12, style: 0), alignment: .left, tabOrder: 0,
                                        content: .repeatGroup([])))
    }
}
