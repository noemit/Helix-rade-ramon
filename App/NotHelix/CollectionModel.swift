import AppKit
import HelixKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case relation(Int)
    case object(Int)
}

enum AppMode: String, CaseIterable, Identifiable {
    case user = "User", design = "Design"
    var id: String { rawValue }
}

@MainActor
final class CollectionModel: ObservableObject {
    /// The Helix file (read-only source).
    let collection: HelixCollection
    /// The editable design: imported from the Helix file once, then edited in Design mode.
    let design: Design
    let fileName: String?
    /// Editable native copy of the data; nil if it could not be created (then read-only).
    let store: RecordStore?
    @Published private(set) var storeError: String?

    @Published var sidebarSelection: SidebarItem?
    @Published var relationID: Int?
    @Published var searchText = ""
    @Published var selectedRecordID: Record.ID?
    @Published private(set) var records: [Record] = []
    @Published private(set) var loadError: String?

    @Published var mode: AppMode = .user
    @Published var openViewID: Int? {
        didSet { if let id = openViewID { UserDefaults.standard.set(id, forKey: lastViewKey) } }
    }
    private var lastViewKey: String { "lastView-\(collection.name)" }
    @Published var viewRecordIndex: [Int: Int] = [:]
    @Published var designPath: [DesignRoute] = []
    @Published var showHistory = false
    /// User-chosen sort order per view (index object id; `recordNumberSort` = record number).
    @Published var sortOverride: [Int: Int] = [:]
    static let recordNumberSort = -1
    /// Bumped on every change so history/undo UI refreshes.
    @Published private(set) var revision = 0
    let undoManager = UndoManager()

    private var cache: [Int: (records: [Record], search: [String])] = [:]
    private var orderedCache: [Int: [Record]] = [:]
    private var evaluatorCache: [String: AbacusEvaluator] = [:]
    private var baseCache: [Int: (records: [Record], modified: Set<UInt32>)] = [:]

    init(collection: HelixCollection, fileName: String?) {
        self.collection = collection
        self.fileName = fileName
        var model: DesignModel?
        do {
            let store = try RecordStore(url: RecordStore.defaultURL(for: collection.heap, name: collection.name))
            try store.importIfNeeded(from: collection)
            model = store.loadDesign()
            if model == nil {
                model = DesignModel(importing: collection)
                try store.saveDesign(model!)
            }
            self.store = store
        } catch {
            store = nil
            storeError = error.localizedDescription
        }
        design = Design(model: model ?? DesignModel(importing: collection), collection: collection)
        let first = design.relations.max { $0.recordCount < $1.recordCount }
        select(.relation(first?.id ?? 0))
        openViewID = first.flatMap { rel in
            let views = design.views(in: rel)
            if UserDefaults.standard.string(forKey: "OpenView") == nil,
               let last = UserDefaults.standard.object(forKey: "lastView-\(design.name)") as? Int,
               views.contains(where: { $0.id == last }) { return last }
            let preferred = UserDefaults.standard.string(forKey: "OpenView") ?? "Lista Xeral"
            return (views.first { $0.name == preferred } ?? views.first)?.id
        }
        // Testing aids: `defaults write com.nothelix.NotHelix OpenRecordText "La taberna de Galiana"`.
        if let text = UserDefaults.standard.string(forKey: "OpenRecordText"), let view = openView,
           let i = records(for: view).firstIndex(where: { r in r.values.values.contains { $0.text == text } }) {
            viewRecordIndex[view.id] = i
        }
        // Testing aids: `defaults write com.nothelix.NotHelix DesignOpen "Libros/Nome completo"`.
        if let path = UserDefaults.standard.string(forKey: "DesignOpen") {
            mode = .design
            var scope = design.model.icons.map(\.objectID)
            for name in path.split(separator: "/").map(String.init) {
                guard let id = scope.first(where: { design.name(of: $0) == name }) else { break }
                if let rel = design.relations.first(where: { $0.id == id }) {
                    designPath.append(.relation(id))
                    scope = rel.iconIDs
                } else {
                    designPath.append(.object(id))
                }
            }
        }
    }

    // MARK: User mode

    /// Views of every relation, sorted by name, as Helix shows them on its user menus.
    var viewsByRelation: [(Relation, [ViewDefinition])] {
        design.relations.map { rel in
            (rel, design.views(in: rel).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }.filter { !$0.1.isEmpty }
    }

    var openView: ViewDefinition? { openViewID.flatMap(design.view(id:)) }

    func relation(ofView view: ViewDefinition) -> Relation? { relationContaining(view.id) }

    func relationContaining(_ objectID: Int) -> Relation? {
        design.relation(containing: objectID)
    }

    func template(for view: ViewDefinition) -> Template? { view.templateID.flatMap(cachedTemplate) }

    /// Records for a view: index order, then the view's query, then the Find field.
    func records(for view: ViewDefinition) -> [Record] { evaluator(for: view)?.records ?? [] }

    /// Evaluator over the view's current record set (summaries and "previous" depend on it).
    func evaluator(for view: ViewDefinition) -> AbacusEvaluator? {
        guard let rel = relation(ofView: view) else { return nil }
        let indexID = sortIndex(for: view)
        let key = "\(view.id)\u{1F}\(indexID ?? 0)\u{1F}\(searchText)"
        if let hit = evaluatorCache[key] { return hit }
        let orderKey = indexID ?? -rel.id
        let ordered: [Record]
        if let hit = orderedCache[orderKey] {
            ordered = hit
        } else {
            let base = baseRecords(rel)
            let keyEval = AbacusEvaluator(design: design, relation: rel, records: base.records)
            ordered = design.order(base.records, relation: rel, byIndex: indexID, modified: base.modified) { r, key in
                rel.field(objectID: key).flatMap { r[$0] } ?? keyEval.value(ofAbacus: key, for: r)
            }
            orderedCache[orderKey] = ordered
        }
        var selected = ordered
        if let q = view.queryID {
            selected = AbacusEvaluator(design: design, relation: rel, records: ordered).select(query: q)
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if !q.isEmpty {
            let terms = q.split(separator: " ")
            selected = selected.filter { r in
                let s = rel.fields.compactMap { r[$0]?.description }.joined(separator: "\u{1F}")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return terms.allSatisfy { s.contains($0) }
            }
        }
        let ev = AbacusEvaluator(design: design, relation: rel, records: selected)
        if evaluatorCache.count > 64 { evaluatorCache.removeAll() }
        evaluatorCache[key] = ev
        return ev
    }

    func sortIndex(for view: ViewDefinition) -> Int? {
        if let o = sortOverride[view.id] { return o == Self.recordNumberSort ? nil : o }
        return view.indexID ?? view.defaultIndexID
    }

    func sortControl(for view: ViewDefinition) -> SortControl? {
        guard let rel = relation(ofView: view) else { return nil }
        let indexes = (design.relationDesign(id: rel.id)?.indexes ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let counts = Dictionary(grouping: indexes, by: \.name).mapValues(\.count)
        var options = indexes.map { idx -> (id: Int, name: String) in
            let keys = idx.keys.compactMap { design.name(of: $0) }
            let name = counts[idx.name, default: 0] > 1 && keys.count > 1 ? "\(idx.name) (\(keys.dropFirst().prefix(2).joined(separator: ", ")))" : idx.name
            return (idx.id, name)
        }
        options.append((Self.recordNumberSort, "Record number"))
        return SortControl(options: options, selection: Binding(
            get: { self.sortIndex(for: view) ?? Self.recordNumberSort },
            set: { self.sortOverride[view.id] = $0; self.viewRecordIndex[view.id] = 0 }))
    }

    func recordIndexBinding(for view: ViewDefinition) -> Binding<Int> {
        Binding(get: { self.viewRecordIndex[view.id] ?? 0 }, set: { self.viewRecordIndex[view.id] = $0 })
    }

    func cachedTemplate(id: Int) -> Template? { design.template(id: id) }

    var relation: Relation? { design.relations.first { $0.id == relationID } }

    var selectedRecord: Record? { records.first { $0.id == selectedRecordID } }

    func select(_ item: SidebarItem?) {
        sidebarSelection = item
        guard case .relation(let id)? = item, id != relationID else { return }
        relationID = id
        selectedRecordID = nil
        load()
    }

    private func load() {
        guard let rel = relation else { records = []; return }
        loadError = nil
        if cache[rel.id] == nil {
            do {
                let recs = baseRecords(rel).records
                let search = recs.map { r in
                    rel.fields.compactMap { r[$0]?.description }.joined(separator: "\u{1F}")
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                }
                cache[rel.id] = (recs, search)
            } catch {
                loadError = error.localizedDescription
                cache[rel.id] = ([], [])
            }
        }
        applySearch()
    }

    func applySearch() {
        guard let rel = relation, let entry = cache[rel.id] else { return }
        let q = searchText.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if q.isEmpty {
            records = entry.records
        } else {
            let terms = q.split(separator: " ")
            records = zip(entry.records, entry.search).filter { _, s in terms.allSatisfy { s.contains($0) } }.map(\.0)
        }
        if let sel = selectedRecordID, !records.contains(where: { $0.id == sel }) { selectedRecordID = nil }
    }

    /// All records of a relation from the native store (or the Helix file if there is no store).
    func baseRecords(_ rel: Relation) -> (records: [Record], modified: Set<UInt32>) {
        if let hit = baseCache[rel.id] { return hit }
        let result: (records: [Record], modified: Set<UInt32>)
        if let store, let recs = try? store.records(ofRelation: rel.id) {
            result = (recs, (try? store.modifiedRecordIDs(ofRelation: rel.id)) ?? [])
        } else {
            result = ((try? collection.records(of: rel)) ?? [], [])
        }
        baseCache[rel.id] = result
        return result
    }

    // MARK: Editing

    var canEdit: Bool { store != nil }

    func nextRecordID(in rel: Relation) throws -> UInt32 {
        guard let store else { throw HelixFormatError("Editing is unavailable: \(storeError ?? "no store")") }
        return try store.nextRecordID(relationID: rel.id)
    }

    func save(_ record: Record, in rel: Relation) throws {
        try apply(record, recordID: record.id, in: rel, actionName: "Replace")
    }

    func delete(_ recordID: UInt32, in rel: Relation) throws {
        try apply(nil, recordID: recordID, in: rel, actionName: "Delete Record")
    }

    /// Sets a record's state, logs it, and registers the inverse with the undo manager
    /// (undoing registers the redo automatically).
    func apply(_ record: Record?, recordID: UInt32, in rel: Relation, actionName: String, note: String = "") throws {
        guard let store else { throw HelixFormatError("Editing is unavailable: \(storeError ?? "no store")") }
        let isUndoing = undoManager.isUndoing, isRedoing = undoManager.isRedoing
        let n = note.isEmpty ? (isUndoing ? "Undo \(actionName)" : isRedoing ? "Redo \(actionName)" : "") : note
        guard let entry = try store.put(record, recordID: recordID, relationID: rel.id, note: n) else { return }
        undoManager.registerUndo(withTarget: self) { m in
            do {
                try m.apply(entry.before, recordID: entry.recordID, in: rel, actionName: actionName)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        undoManager.setActionName(entry.action == .insert ? "Enter Record" : actionName)
        invalidate(rel)
    }

    /// Restores a record to how it was before a logged change (from the History panel).
    func restore(before entry: RecordStore.HistoryEntry) {
        guard let rel = design.relations.first(where: { $0.id == entry.relationID }) else { return }
        do {
            try apply(entry.before, recordID: entry.recordID, in: rel, actionName: "Restore",
                      note: "Restored to before change #\(entry.id)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func history() -> [RecordStore.HistoryEntry] { (try? store?.history()) ?? [] }

    /// A short human label for a record: its first two non-empty text fields.
    func label(for record: Record?, in rel: Relation) -> String {
        guard let record else { return "" }
        let parts = rel.fields.compactMap { f -> String? in
            if case .text(let s)? = record[f], !s.isEmpty { s.components(separatedBy: .newlines).first } else { nil }
        }
        return parts.prefix(2).joined(separator: " — ")
    }

    // MARK: Design editing

    /// Applies a design change: saves it, logs it in the History, and makes it undoable.
    @discardableResult
    func editDesign<T>(_ actionName: String, _ change: (inout DesignModel) -> T) -> T {
        let before = design.model
        let result = design.update(change)
        commitDesign(actionName, before: before)
        return result
    }

    private func commitDesign(_ actionName: String, before: DesignModel) {
        guard design.model != before else { return }
        let prefix = undoManager.isUndoing ? "Undo " : undoManager.isRedoing ? "Redo " : ""
        do {
            try store?.saveDesign(design.model, note: prefix + actionName)
        } catch {
            NSAlert(error: error).runModal()
        }
        undoManager.registerUndo(withTarget: self) { m in
            let current = m.design.model
            m.design.replace(with: before)
            m.commitDesign(actionName, before: current)
        }
        undoManager.setActionName(actionName)
        designChanged()
    }

    /// Clears everything derived from the design.
    func designChanged() {
        orderedCache.removeAll()
        evaluatorCache.removeAll()
        cache.removeAll()
        revision += 1
        if relationID != nil { load() }
        if let id = openViewID, design.view(id: id) == nil { openViewID = viewsByRelation.first?.1.first?.id }
    }

    /// Names of the design objects that refer to `id` (shown before deleting).
    func usages(of id: Int) -> [String] {
        var out: [String] = []
        for r in design.model.relations {
            for t in r.templates where TemplateElement.flatten(t.elements).contains(where: {
                if case .data(let f, let a) = $0.content { f == id || a == id } else { false }
            }) { out.append("Template “\(t.name)”") }
            for a in r.abaci where a.id != id && (a.root?.references.contains(id) ?? false) {
                if let q = r.queries.first(where: { $0.abacusID == a.id }) { out.append("Query “\(q.name)”") }
                else { out.append("Abacus “\(a.name)”") }
            }
            for v in r.views where [v.templateID, v.queryID, v.indexID, v.defaultIndexID].contains(id) {
                out.append("View “\(v.name)”")
            }
            for x in r.indexes where x.keys.contains(id) { out.append("Index “\(x.name)”") }
        }
        return out
    }

    func actions(for view: ViewDefinition) -> RecordActions? {
        guard canEdit, let rel = relation(ofView: view) else { return nil }
        return RecordActions(
            nextID: { [unowned self] in try nextRecordID(in: rel) },
            save: { [unowned self] in try save($0, in: rel) },
            delete: { [unowned self] in try delete($0, in: rel) },
            group: { [unowned self] name, body in
                undoManager.beginUndoGrouping()
                defer {
                    undoManager.endUndoGrouping()
                    undoManager.setActionName(name)
                }
                try body()
            },
            position: { [unowned self] id in records(for: view).firstIndex { $0.id == id } })
    }

    private func invalidate(_ rel: Relation) {
        baseCache[rel.id] = nil
        cache[rel.id] = nil
        orderedCache.removeAll()
        evaluatorCache.removeAll()
        revision += 1
        if rel.id == relationID { load() }
    }

    var totalRecordCount: Int { relation.flatMap { cache[$0.id]?.records.count } ?? 0 }

    @Published var showExport = false

    /// The view whose records the Export sheet uses (the open view in User mode).
    var exportView: ViewDefinition? {
        if mode == .design, case .object(let id)? = designPath.last, let v = design.view(id: id) { return v }
        return openView
    }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(design.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.json(collection) { [unowned self] rel in baseRecords(rel).records }.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveDatabaseCopy() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.nameFieldStringValue = "\(design.name).sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.backup(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func revealDatabase() {
        guard let store else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }
}
