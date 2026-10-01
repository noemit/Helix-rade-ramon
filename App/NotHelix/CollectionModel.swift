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
    var label: String { self == .user ? L("User") : L("Design") }
}

@MainActor
final class CollectionModel: ObservableObject {
    let id = UUID()
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
        didSet {
            guard let id = openViewID else { return }
            UserDefaults.standard.set(id, forKey: lastViewKey)
            if let v = design.view(id: id), template(for: v)?.repeatElement == nil, let rel = relation(ofView: v) {
                UserDefaults.standard.set(id, forKey: "lastForm-\(collection.name)-\(rel.id)")
            }
        }
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
    private var searchCache: [Int: [UInt32: String]] = [:]

    /// A drill-down filter on a view (clicked value) or a single record opened from a list.
    struct Drill: Equatable, CustomStringConvertible {
        var title: String
        var keyID: Int?
        var value: Value?
        var recordID: UInt32?
        /// Find-by-form criteria: field object id → criterion text (see `FindCriteria`).
        var criteria: [Int: String] = [:]
        var description: String {
            "\(keyID ?? 0)|\(value?.description ?? "")|\(recordID ?? 0)|" + criteria.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        }
    }

    struct BackEntry {
        let viewID: Int
        let drill: Drill?
        let index: Int
    }

    @Published var drills: [Int: Drill] = [:]
    @Published var backStack: [BackEntry] = []

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
        try? store?.backupIfNeeded()
        ModelRegistry.register(self)
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
        // Testing aids: `SearchText "Chao Rego, Xosé"` fills Find; `ClickText "Chao Rego"` clicks the first
        // list cell showing that text (drill-down).
        if let q = UserDefaults.standard.string(forKey: "SearchText") { searchText = q }
        if let text = UserDefaults.standard.string(forKey: "ClickText"), let view = openView, let rel = relation(ofView: view),
           let t = template(for: view), let ev = evaluator(for: view) {
            let cells = TemplateElement.flatten(t.repeatElement.map { [$0] } ?? [])
            outer: for r in records(for: view) {
                for e in cells {
                    let ctx = TemplateContext(design: design, relation: rel, record: r, evaluator: ev)
                    if let (s, _) = ctx.text(for: e), s.contains(text) {
                        drill(into: e, record: r, in: view, title: nil)
                        break outer
                    }
                }
            }
        }
        // Testing aid: `PrintPDFTo /tmp/x.pdf` writes the open view's print output.
        if let path = UserDefaults.standard.string(forKey: "PrintPDFTo"), let job = printJob(allRecords: false) {
            try? ViewPrinter.pdf(job).write(to: URL(fileURLWithPath: path))
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
        let drill = drills[view.id]
        let key = "\(view.id)\u{1F}\(indexID ?? 0)\u{1F}\(searchText)\u{1F}\(drill.map { "\($0)" } ?? "")"
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
        let query = TextSearch.words(searchText)
        if !query.isEmpty {
            let hay = searchIndex(rel)
            selected = selected.filter { TextSearch.matches(hay[$0.id] ?? "", query: query) }
        }
        if let drill {
            for (fid, crit) in drill.criteria {
                guard let f = rel.field(objectID: fid) else { continue }
                selected = selected.filter { FindCriteria.matches($0[f], crit, type: f.type) }
            }
            if let rid = drill.recordID {
                selected = selected.filter { $0.id == rid }
            } else if let keyID = drill.keyID {
                let keyEval = drillEvaluator(rel)
                selected = selected.filter { TextSearch.same(keyValue(keyID, $0, rel, keyEval), drill.value) }
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
        options.append((Self.recordNumberSort, L("Record number")))
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
                let hay = searchIndex(rel)
                cache[rel.id] = (recs, recs.map { hay[$0.id] ?? "" })
            } catch {
                loadError = error.localizedDescription
                cache[rel.id] = ([], [])
            }
        }
        applySearch()
    }

    func applySearch() {
        guard let rel = relation, let entry = cache[rel.id] else { return }
        let query = TextSearch.words(searchText)
        records = query.isEmpty ? entry.records
            : zip(entry.records, entry.search).filter { TextSearch.matches($1, query: query) }.map(\.0)
        if let sel = selectedRecordID, !records.contains(where: { $0.id == sel }) { selectedRecordID = nil }
    }

    // MARK: Search and drill-down

    /// Normalised search text per record (see `TextSearch`).
    func searchIndex(_ rel: Relation) -> [UInt32: String] {
        if let hit = searchCache[rel.id] { return hit }
        let idx = Dictionary(baseRecords(rel).records.map { ($0.id, TextSearch.haystack(for: $0, in: rel)) },
                             uniquingKeysWith: { a, _ in a })
        searchCache[rel.id] = idx
        return idx
    }

    /// Evaluator that ignores "previous", so non-repeated columns give every record's value.
    private func drillEvaluator(_ rel: Relation) -> AbacusEvaluator {
        let ev = AbacusEvaluator(design: design, relation: rel, records: baseRecords(rel).records)
        ev.ignorePrevious = true
        return ev
    }

    private func keyValue(_ keyID: Int, _ r: Record, _ rel: Relation, _ ev: AbacusEvaluator) -> Value? {
        if let f = rel.field(objectID: keyID) { return r[f] }
        return ev.value(ofAbacus: keyID, for: r)
    }

    /// Clicked a value in a list: show only records with the same value in that column.
    /// If that leaves a single record (usually a title), open it on a form instead.
    func drill(into element: TemplateElement, record: Record, in view: ViewDefinition, title: String?) {
        guard let rel = relation(ofView: view), case .data(let fid, let aid) = element.content,
              let keyID = fid ?? aid else { return }
        let ev = drillEvaluator(rel)
        let value = keyValue(keyID, record, rel, ev)
        guard value != nil else { open(record, from: view); return }
        let current = records(for: view)
        let matches = current.filter { TextSearch.same(keyValue(keyID, $0, rel, ev), value) }
        if matches.count <= 1 || drills[view.id]?.keyID == keyID { open(record, from: view); return }
        pushBack()
        let column = template(for: view).flatMap { t in t.repeatElement.map { ListLayout(template: t, repeatElement: $0).columnTitle(for: element) } } ?? nil
        let label = title ?? column ?? design.name(of: keyID) ?? ""
        drills[view.id] = Drill(title: "\(label): \(value!.description.components(separatedBy: .newlines).first ?? "")",
                                keyID: keyID, value: value, recordID: nil)
        viewRecordIndex[view.id] = 0
    }

    /// Opens a record on the relation's most detailed form view.
    func open(_ record: Record, from view: ViewDefinition) {
        guard let rel = relation(ofView: view), let form = formView(for: rel, preferring: view) else { return }
        pushBack()
        drills[form.id] = nil
        if let i = records(for: form).firstIndex(where: { $0.id == record.id }) {
            viewRecordIndex[form.id] = i
        } else {
            drills[form.id] = Drill(title: label(for: record, in: rel), keyID: nil, value: nil, recordID: record.id)
            viewRecordIndex[form.id] = 0
        }
        openViewID = form.id
    }

    /// The form to open a record on: the last form used for this relation, otherwise the one
    /// with the largest layout (Helix collections usually have one main "card", e.g. Ficha).
    func formView(for rel: Relation, preferring current: ViewDefinition) -> ViewDefinition? {
        let forms = design.views(in: rel).filter { template(for: $0).map { $0.repeatElement == nil } ?? false }
        if forms.contains(where: { $0.id == current.id }) { return current }
        if let last = UserDefaults.standard.object(forKey: "lastForm-\(collection.name)-\(rel.id)") as? Int,
           let v = forms.first(where: { $0.id == last }) { return v }
        func area(_ v: ViewDefinition) -> Int { template(for: v).map { $0.contentBounds.width * $0.contentBounds.height } ?? 0 }
        return forms.max { a, b in area(a) != area(b) ? area(a) < area(b) : a.name > b.name }
    }

    private func pushBack() {
        guard let id = openViewID else { return }
        backStack.append(BackEntry(viewID: id, drill: drills[id], index: viewRecordIndex[id] ?? 0))
        if backStack.count > 50 { backStack.removeFirst() }
    }

    func goBack() {
        guard let e = backStack.popLast() else { return }
        drills[e.viewID] = e.drill
        viewRecordIndex[e.viewID] = e.index
        openViewID = e.viewID
    }

    func navigation(for view: ViewDefinition) -> ListNavigation {
        ListNavigation(
            filterTitle: drills[view.id]?.title,
            clearFilter: { [unowned self] in clearDrill(view) },
            activate: { [unowned self] e, r, title in drill(into: e, record: r, in: view, title: title) },
            open: { [unowned self] r in open(r, from: view) },
            find: { [unowned self] criteria in find(criteria, in: view) })
    }

    /// Find by form: show only records matching the criteria typed into the form's fields.
    func find(_ criteria: [Int: String], in view: ViewDefinition) {
        let crit = criteria.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !crit.isEmpty else { clearDrill(view); return }
        pushBack()
        let title = crit.sorted { $0.key < $1.key }
            .map { "\(design.name(of: $0.key) ?? "?") \($0.value.first.map { "=≠<>≤≥".contains($0) } == true ? "" : "~ ")\($0.value)" }
            .joined(separator: ", ")
        drills[view.id] = Drill(title: L("Find: \(title)"), keyID: nil, value: nil, recordID: nil, criteria: crit)
        viewRecordIndex[view.id] = 0
    }

    func clearDrill(_ view: ViewDefinition) {
        drills[view.id] = nil
        viewRecordIndex[view.id] = 0
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
        guard let store else { throw HelixFormatError(L("Editing is unavailable: \(storeError ?? "no store")")) }
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
        guard let store else { throw HelixFormatError(L("Editing is unavailable: \(storeError ?? "no store")")) }
        let isUndoing = undoManager.isUndoing, isRedoing = undoManager.isRedoing
        let n = note.isEmpty ? (isUndoing ? L("Undo \(Lk(actionName))") : isRedoing ? L("Redo \(Lk(actionName))") : "") : note
        guard let entry = try store.put(record, recordID: recordID, relationID: rel.id, note: n) else { return }
        undoManager.registerUndo(withTarget: self) { m in
            do {
                try m.apply(entry.before, recordID: entry.recordID, in: rel, actionName: actionName)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        undoManager.setActionName(entry.action == .insert ? L("Enter Record") : Lk(actionName))
        invalidate(rel)
    }

    /// Restores a record to how it was before a logged change (from the History panel).
    func restore(before entry: RecordStore.HistoryEntry) {
        guard let rel = design.relations.first(where: { $0.id == entry.relationID }) else { return }
        do {
            try apply(entry.before, recordID: entry.recordID, in: rel, actionName: "Restore",
                      note: L("Restored to before change #\(entry.id)"))
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
        let note = undoManager.isUndoing ? L("Undo \(Lk(actionName))") : undoManager.isRedoing ? L("Redo \(Lk(actionName))") : Lk(actionName)
        do {
            try store?.saveDesign(design.model, note: note)
        } catch {
            NSAlert(error: error).runModal()
        }
        undoManager.registerUndo(withTarget: self) { m in
            let current = m.design.model
            m.design.replace(with: before)
            m.commitDesign(actionName, before: current)
        }
        undoManager.setActionName(Lk(actionName))
        designChanged()
    }

    /// Clears everything derived from the design.
    func designChanged() {
        orderedCache.removeAll()
        evaluatorCache.removeAll()
        cache.removeAll()
        searchCache.removeAll()
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
            }) { out.append(L("Template “\(t.name)”")) }
            for a in r.abaci where a.id != id && (a.root?.references.contains(id) ?? false) {
                if let q = r.queries.first(where: { $0.abacusID == a.id }) { out.append(L("Query “\(q.name)”")) }
                else { out.append(L("Abacus “\(a.name)”")) }
            }
            for v in r.views where [v.templateID, v.queryID, v.indexID, v.defaultIndexID].contains(id) {
                out.append(L("View “\(v.name)”"))
            }
            for x in r.indexes where x.keys.contains(id) { out.append(L("Index “\(x.name)”")) }
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
        searchCache[rel.id] = nil
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

    // MARK: Printing

    /// The view to print (open view in User mode, or a view opened in Design mode).
    func printJob(allRecords: Bool) -> ViewPrinter.Job? {
        guard let view = exportView, let rel = relation(ofView: view), let t = template(for: view),
              let ev = evaluator(for: view) else { return nil }
        var recs = ev.records
        if t.repeatElement == nil, !allRecords {
            let i = min(viewRecordIndex[view.id] ?? 0, max(0, recs.count - 1))
            recs = recs.isEmpty ? [] : [recs[i]]
        }
        return ViewPrinter.Job(title: view.name, template: t, design: design, relation: rel, records: recs, evaluator: ev)
    }

    var printIsForm: Bool { exportView.flatMap(template(for:))?.repeatElement == nil }

    func printView(allRecords: Bool) { if let j = printJob(allRecords: allRecords) { ViewPrinter.print(j) } }
    func exportPDF() { if let j = printJob(allRecords: true) { ViewPrinter.savePDF(j) } }

    // MARK: Updating from Helix, backups

    /// Brings in records (and new fields) from a newer copy of the Helix file. Records edited
    /// in Faulix are kept. A backup is made first.
    func updateFromHelix() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.message = L("Choose the newer copy of “\(collection.name)” exported from Helix.")
        panel.prompt = L("Update")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let newer = try HelixCollection(url: url)
            try store.backupIfNeeded(force: true)
            var m = design.model
            let report = try store.merge(from: newer, original: collection, design: &m)
            store.registerAlias(for: newer.heap)
            design.replace(with: m)
            undoManager.removeAllActions()
            baseCache.removeAll()
            searchCache.removeAll()
            designChanged()
            let alert = NSAlert()
            alert.messageText = L("Updated from “\(url.lastPathComponent)”")
            var lines = [L("\(report.added) new, \(report.updated) changed, \(report.deleted) removed, \(report.unchanged) unchanged.")]
            if !report.newFields.isEmpty {
                let names = report.newFields.joined(separator: ", ")
                lines.append(L("New fields: \(names)."))
            }
            if !report.conflicts.isEmpty {
                lines.append(L("\(report.conflicts.count) record(s) were changed both in Helix and in Faulix; the Faulix version was kept."))
            }
            lines.append(L("A backup was made first (Data ▸ Show Backups in Finder)."))
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func showBackups() {
        guard let store else { return }
        try? FileManager.default.createDirectory(at: store.backupFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.backupFolder)
    }

    func backUpNow() {
        do {
            if let url = try store?.backupIfNeeded(force: true) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func revealDatabase() {
        guard let store else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }
}
