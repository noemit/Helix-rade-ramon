import AppKit
import HelixKit
import SwiftUI

// MARK: Shared editing plumbing

/// Operations a view can perform on the record store.
struct RecordActions {
    let nextID: () throws -> UInt32
    let save: (Record) throws -> Void
    let delete: (UInt32) throws -> Void
    /// Runs several saves/deletes as one undoable step.
    let group: (String, () throws -> Void) throws -> Void
    /// Position of a record in the view's (refreshed) record list.
    let position: (UInt32) -> Int?
}

/// The Helix "Sort Order" popup: which index orders the view.
struct SortControl {
    let options: [(id: Int, name: String)]
    let selection: Binding<Int>
}

struct DraftError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum RecordDraft {
    /// Applies typed text and flag changes to a record, validating numbers and dates.
    static func apply(text: [UInt16: String], flags: [UInt16: Bool], to base: Record, relation: Relation) throws -> Record {
        var r = base
        for (fid, s) in text {
            guard let f = relation.field(withID: fid) else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            switch f.type {
            case .number:
                guard t.isEmpty || AbacusEvaluator.parseNumber(t) != nil else { throw DraftError(message: "“\(f.displayName)” needs a number.") }
                r[f] = AbacusEvaluator.parseNumber(t).map(Value.number)
            case .date:
                guard t.isEmpty || AbacusEvaluator.parseDate(t) != nil else {
                    throw DraftError(message: "“\(f.displayName)” needs a date such as 30-9-2026.")
                }
                r[f] = AbacusEvaluator.parseDate(t).map(Value.date)
            default:
                r[f] = s.isEmpty ? nil : .text(s)
            }
        }
        for (fid, b) in flags { r.values[fid] = .flag(b) }
        return r
    }

    /// A blank record with Helix default values: rectangles holding both a field and an
    /// abacus use the abacus as the field's default.
    static func newRecord(id: UInt32, template: Template, relation: Relation, evaluator: AbacusEvaluator) -> Record {
        var r = Record(id: id, values: [:])
        for e in TemplateCanvas.flatten(template.elements) {
            if case .data(let fid?, let aid?) = e.content, let f = relation.field(objectID: fid),
               let v = evaluator.value(ofAbacus: aid, for: r) {
                r[f] = f.type == .text ? .text(editingText(v)) : v
            }
        }
        return r
    }
}

/// Uncommitted edits for one or more records.
@MainActor
final class Drafts: ObservableObject {
    @Published var text: [UInt32: [UInt16: String]] = [:]
    @Published var flags: [UInt32: [UInt16: Bool]] = [:]
    @Published var newRecords: [Record] = []
    @Published var revision = 0

    var dirtyIDs: Set<UInt32> { Set(text.keys).union(flags.keys).union(newRecords.map(\.id)) }
    var isDirty: Bool { !dirtyIDs.isEmpty }
    func isNew(_ id: UInt32) -> Bool { newRecords.contains { $0.id == id } }

    func editing(for record: Record) -> FieldEditing {
        let rid = record.id
        return FieldEditing(
            changed: { [unowned self] f in text[rid]?[f.fieldID] != nil || flags[rid]?[f.fieldID] != nil },
            text: { [unowned self] f in text[rid]?[f.fieldID] ?? editingText(record[f]) },
            setText: { [unowned self] f, s in
                var d = text[rid] ?? [:]
                d[f.fieldID] = s == editingText(record[f]) ? nil : s
                text[rid] = d.isEmpty ? nil : d
            },
            flag: { [unowned self] f in flags[rid]?[f.fieldID] ?? { if case .flag(true)? = record[f] { true } else { false } }() },
            setFlag: { [unowned self] f, b in
                var d = flags[rid] ?? [:]
                d[f.fieldID] = b
                flags[rid] = d
            })
    }

    /// Builds the final records for every dirty id, or throws the first validation error.
    func build(_ base: (UInt32) -> Record?, relation: Relation) throws -> [Record] {
        try dirtyIDs.sorted().compactMap { id in
            guard let b = newRecords.first(where: { $0.id == id }) ?? base(id) else { return nil }
            return try RecordDraft.apply(text: text[id] ?? [:], flags: flags[id] ?? [:], to: b, relation: relation)
        }
    }

    func reset() {
        text = [:]
        flags = [:]
        newRecords = []
        revision += 1
    }
}

// MARK: View pane

/// A Helix view in User mode: a form (one record at a time) or a list (repeat rectangle),
/// shown as a sheet of paper on a desk with a status bar underneath.
struct HelixViewPane: View {
    let view: ViewDefinition
    let template: Template
    let collection: HelixCollection
    let relation: Relation
    let records: [Record]
    let evaluator: AbacusEvaluator
    var actions: RecordActions?
    var sort: SortControl?
    @Binding var currentIndex: Int

    var body: some View {
        Group {
            if let rep = template.repeatElement {
                ListForm(template: template, repeatElement: rep, collection: collection, relation: relation, records: records,
                         evaluator: evaluator, actions: actions, sort: sort)
            } else {
                SingleForm(template: template, collection: collection, relation: relation, records: records,
                           evaluator: evaluator, actions: actions, sort: sort, currentIndex: $currentIndex)
            }
        }
        .navigationTitle(view.name)
        .environment(\.colorScheme, .light)
    }
}

/// Grey desk with the template drawn on white paper.
struct Paper<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            content
                .frame(width: width, alignment: .topLeading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(20)
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(white: 0.92))
    }
}

/// Bottom bar shared by forms and lists: New/Delete · centre content · Sort, Revert, Enter/Replace.
struct StatusBar<Center: View>: View {
    let actions: RecordActions?
    let sort: SortControl?
    let dirty: Bool
    let canDelete: Bool
    let commitTitle: String
    let onNew: () -> Void
    let onDelete: () -> Void
    let onRevert: () -> Void
    let onCommit: () -> Void
    @ViewBuilder let center: Center

    var body: some View {
        HStack(spacing: 10) {
            if actions != nil {
                Button(action: onNew) { Label("New", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("New record (⇧⌘N)")
                Button(action: onDelete) { Label("Delete", systemImage: "trash") }
                    .disabled(!canDelete)
                    .help("Delete record")
            }
            Spacer(minLength: 8)
            center
            Spacer(minLength: 8)
            if let sort {
                Picker(selection: sort.selection) {
                    ForEach(sort.options, id: \.id) { Text($0.name).tag($0.id) }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .fixedSize()
                .disabled(dirty)
                .help("Sort order")
            }
            if actions != nil {
                Button("Revert", action: onRevert)
                    .disabled(!dirty)
                    .keyboardShortcut(.escape, modifiers: [])
                Button(commitTitle, action: onCommit)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
                    .help("Save changes (⌘S)")
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: Form

/// One record at a time, editable like a Helix entry form: type into fields, then
/// Enter (new record) or Replace (existing record).
struct SingleForm: View {
    let template: Template
    let collection: HelixCollection
    let relation: Relation
    let records: [Record]
    let evaluator: AbacusEvaluator
    let actions: RecordActions?
    let sort: SortControl?
    @Binding var currentIndex: Int

    @StateObject private var drafts = Drafts()
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private var current: Record? { records.indices.contains(currentIndex) ? records[currentIndex] : nil }
    private var base: Record? { drafts.newRecords.first ?? current }

    var body: some View {
        let b = template.contentBounds
        VStack(spacing: 0) {
            if let base {
                Paper(width: CGFloat(b.right + 16)) {
                    TemplateCanvas(elements: template.elements,
                                   context: TemplateContext(collection: collection, relation: relation, record: base,
                                                            evaluator: evaluator,
                                                            editor: actions == nil ? nil : drafts.editing(for: base)))
                        .frame(width: CGFloat(b.right + 16), height: CGFloat(b.bottom + 16), alignment: .topLeading)
                        .padding(4)
                        .id("\(base.id)-\(drafts.revision)")
                }
            } else {
                ContentUnavailableView("No Records", systemImage: "doc", description: Text("No records match."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.92))
            }
            StatusBar(actions: actions, sort: sort, dirty: drafts.isDirty, canDelete: base != nil && drafts.newRecords.isEmpty,
                      commitTitle: drafts.newRecords.isEmpty ? "Replace" : "Enter",
                      onNew: startNew, onDelete: { confirmDelete = true }, onRevert: drafts.reset, onCommit: commit) {
                navigation
            }
        }
        .onChange(of: records.count) { currentIndex = min(currentIndex, max(0, records.count - 1)) }
        .alert("Cannot Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Delete this record?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: deleteRecord)
        } message: { Text("You can undo this, and it stays in the History. The original Helix file is never changed.") }
    }

    private var navigation: some View {
        HStack(spacing: 14) {
            Button { currentIndex = 0 } label: { Image(systemName: "backward.end.fill") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button { currentIndex = max(0, currentIndex - 1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Group {
                if !drafts.newRecords.isEmpty {
                    Text("New record")
                } else if records.isEmpty {
                    Text("No records")
                } else {
                    Text("\(currentIndex + 1)").bold() + Text(" of \(records.count)")
                }
            }
            .monospacedDigit()
            .frame(minWidth: 110)
            Button { currentIndex = min(records.count - 1, currentIndex + 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button { currentIndex = max(0, records.count - 1) } label: { Image(systemName: "forward.end.fill") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .labelStyle(.iconOnly)
        .disabled(records.isEmpty || drafts.isDirty)
        .help(drafts.isDirty ? "Replace or revert your changes first" : "⌘↑ / ⌘↓ to move between records")
    }

    private func startNew() {
        guard let actions else { return }
        do {
            drafts.reset()
            drafts.newRecords = [RecordDraft.newRecord(id: try actions.nextID(), template: template, relation: relation, evaluator: evaluator)]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        guard let actions else { return }
        do {
            let built = try drafts.build({ id in current?.id == id ? current : nil }, relation: relation)
            try actions.group(drafts.newRecords.isEmpty ? "Replace" : "Enter Record") { try built.forEach(actions.save) }
            drafts.reset()
            if let id = built.first?.id, let p = actions.position(id) { currentIndex = p }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRecord() {
        guard let actions, let r = current else { return }
        do {
            try actions.delete(r.id)
            drafts.reset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: List

/// A list view built from the template's repeat rectangle. Rows are editable in place;
/// changed rows are marked and saved together with Replace.
struct ListForm: View {
    let template: Template
    let repeatElement: TemplateElement
    let collection: HelixCollection
    let relation: Relation
    let records: [Record]
    let evaluator: AbacusEvaluator
    let actions: RecordActions?
    let sort: SortControl?

    @StateObject private var drafts = Drafts()
    @State private var selected: UInt32?
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    var body: some View {
        let layout = ListLayout(template: template, repeatElement: repeatElement)
        let rows = drafts.newRecords + records
        VStack(spacing: 0) {
            Paper(width: layout.width) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { rec in row(rec, layout) }
                        if !layout.footer.isEmpty {
                            TemplateCanvas(elements: layout.footer, context: context(records.first))
                                .offset(y: CGFloat(-layout.rep.bottom))
                                .frame(width: layout.width, height: layout.footerHeight, alignment: .topLeading)
                        }
                    } header: {
                        TemplateCanvas(elements: layout.header, context: context(records.first))
                            .frame(width: layout.width, height: layout.headerHeight, alignment: .topLeading)
                            .background(Color.white)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.15)).frame(height: 1) }
                    }
                }
                .id(drafts.revision)
            }
            StatusBar(actions: actions, sort: sort, dirty: drafts.isDirty, canDelete: selected != nil,
                      commitTitle: drafts.newRecords.isEmpty ? "Replace" : "Enter",
                      onNew: addRow, onDelete: { confirmDelete = true }, onRevert: drafts.reset, onCommit: commit) {
                Group {
                    let changed = drafts.dirtyIDs.count
                    Text("\(records.count) records") + Text(changed > 0 ? "  ·  \(changed) changed" : "").foregroundColor(.orange)
                }
                .monospacedDigit()
            }
        }
        .alert("Cannot Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Delete the selected record?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: deleteSelected)
        } message: { Text("You can undo this, and it stays in the History. The original Helix file is never changed.") }
    }

    private func context(_ record: Record?, editing: Bool = false) -> TemplateContext {
        TemplateContext(collection: collection, relation: relation, record: record, evaluator: evaluator,
                        editor: editing && actions != nil ? record.map(drafts.editing(for:)) : nil)
    }

    private func row(_ rec: Record, _ layout: ListLayout) -> some View {
        let dirty = drafts.dirtyIDs.contains(rec.id)
        return TemplateCanvas(elements: layout.rowElements, context: context(rec, editing: true))
            .offset(y: CGFloat(-layout.rep.top))
            .frame(width: layout.width, height: CGFloat(layout.stride), alignment: .topLeading)
            .clipped()
            .background(selected == rec.id ? Color.accentColor.opacity(0.10) : Color.clear)
            .overlay(alignment: .leading) {
                if dirty { Rectangle().fill(Color.orange).frame(width: 3) }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { selected = rec.id })
    }

    private func addRow() {
        guard let actions else { return }
        do {
            let id = max(try actions.nextID(), (drafts.newRecords.map(\.id).max() ?? 0) + 1)
            let r = RecordDraft.newRecord(id: id, template: template, relation: relation, evaluator: evaluator)
            drafts.newRecords.insert(r, at: 0)
            selected = r.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        guard let actions else { return }
        do {
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let built = try drafts.build({ byID[$0] }, relation: relation)
            try actions.group(built.count == 1 ? "Replace" : "Replace \(built.count) Records") { try built.forEach(actions.save) }
            drafts.reset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let id = selected else { return }
        if drafts.isNew(id) {
            drafts.newRecords.removeAll { $0.id == id }
        } else if let actions {
            do {
                try actions.delete(id)
                drafts.text[id] = nil
                drafts.flags[id] = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        selected = nil
    }
}

/// Splits a list template into a pinned header, the repeating row and a footer.
struct ListLayout {
    let rep: HelixRect
    let stride: Int
    let rowElements: [TemplateElement]
    let header: [TemplateElement]
    let footer: [TemplateElement]
    let width: CGFloat
    let headerHeight: CGFloat
    let footerHeight: CGFloat

    init(template: Template, repeatElement: TemplateElement) {
        let rep = repeatElement.rect
        self.rep = rep
        stride = max(rep.height, 1)
        if case .repeatGroup(let c) = repeatElement.content { rowElements = TemplateCanvas.flatten(c) } else { rowElements = [] }
        let rowIDs = Set(rowElements.map(\.id))
        let outside = TemplateCanvas.flatten(template.elements).filter { !rowIDs.contains($0.id) }
        let top = rep.top
        // Elements beside the repeat band (e.g. record counts, totals) stay where they are,
        // so the pinned header grows to include them.
        header = outside.filter { $0.rect.top < rep.bottom }
        footer = outside.filter { $0.rect.top >= rep.bottom }
        width = CGFloat(template.contentBounds.right + 12)
        headerHeight = CGFloat(max(top, header.map(\.rect.bottom).max() ?? 1))
        footerHeight = CGFloat(max(0, (footer.map(\.rect.bottom).max() ?? rep.bottom) - rep.bottom))
    }
}
