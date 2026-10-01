import HelixKit
import SwiftUI

/// Screens reachable from the Design-mode desktop, like the windows RADE opens on double-click.
enum DesignRoute: Hashable {
    case relation(Int)
    case object(Int)
    case records(Int)
}

enum IconDisplayMode: String, CaseIterable, Identifiable {
    case icon = "Icon", list = "List"
    var id: String { rawValue }
}

struct DesignModeView: View {
    @ObservedObject var model: CollectionModel

    var body: some View {
        NavigationStack(path: $model.designPath) {
            IconDesktop(model: model, relationID: nil)
                .navigationDestination(for: DesignRoute.self) { route in
                    switch route {
                    case .relation(let id): IconDesktop(model: model, relationID: id)
                    case .records(let id): RecordsBrowser(model: model, relationID: id)
                    case .object(let id): ObjectEditor(model: model, objectID: id)
                    }
                }
        }
    }
}

// MARK: Icon desktop

/// A collection window (relationID nil) or relation window in RADE style: icons at their saved
/// positions (drag to move), or a list. New, Rename, Duplicate and Delete edit the design.
struct IconDesktop: View {
    @ObservedObject var model: CollectionModel
    let relationID: Int?

    @AppStorage("iconDisplayMode") private var displayMode: IconDisplayMode = .icon
    @State private var selection: Int?
    @State private var drag: (id: Int, offset: CGSize)?
    @State private var renaming: Int?
    @State private var deleting: Int?
    @State private var creating: ObjectKind?

    private var design: Design { model.design }
    private var relation: Relation? { relationID.flatMap(design.relation(id:)) }
    private var icons: [IconPlacement] {
        let _ = model.revision
        return (relation?.icons ?? design.model.icons).filter { design.kind(of: $0.objectID) != nil }
    }
    private var title: String { relation?.name ?? design.name }

    var body: some View {
        Group {
            switch displayMode {
            case .icon: iconMode
            case .list: listMode
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Menu {
                    if relationID == nil {
                        Button("Relation…") { creating = .relation }
                    } else {
                        Button("Field…") { creating = .field }
                        Button("Abacus…") { creating = .abacus }
                        Button("Template…") { creating = .template }
                        Button("View…") { creating = .view }
                        Button("Query…") { creating = .query }
                        Button("Index…") { creating = .index }
                    }
                } label: { Label("New", systemImage: "plus") }
                .help(relationID == nil ? "Add a relation" : "Add a field, abacus, template, view, query or index")
            }
            if let relationID {
                ToolbarItem {
                    Button { model.designPath.append(.records(relationID)) } label: { Label("Browse Records", systemImage: "tablecells") }
                        .help("Browse all records of this relation in a table")
                }
            }
            ToolbarItem {
                Picker("Display", selection: $displayMode) {
                    ForEach(IconDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Display icons at their positions, or as a list")
            }
            ToolbarItem { HelpButton(topic: relationID == nil ? .collection : .relation) }
        }
        .sheet(item: $creating) { kind in
            NewObjectSheet(model: model, kind: kind, relationID: relationID) { id in
                if let id, kind != .field, kind != .relation { model.designPath.append(.object(id)) }
                selection = id
            }
        }
        .sheet(item: Binding(get: { renaming.map(IdentifiedInt.init) }, set: { renaming = $0?.id })) { item in
            RenameSheet(name: design.name(of: item.id) ?? "") { newName in
                model.editDesign("Rename") { $0.rename(item.id, to: newName) }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = deleting { model.editDesign("Delete \(design.kind(of: id)?.displayName ?? "Icon")") { $0.delete(id) } }
            }
        } message: { Text(deleteMessage) }
        .onDeleteCommand { if let s = selection { deleting = s } }
    }

    private var deleteTitle: String {
        guard let id = deleting else { return "" }
        return "Delete \(design.kind(of: id)?.displayName.lowercased() ?? "icon") “\(design.name(of: id) ?? "")”?"
    }

    private var deleteMessage: String {
        guard let id = deleting else { return "" }
        var parts: [String] = []
        if design.kind(of: id) == .relation { parts.append("Its records stay in the database but will no longer be shown.") }
        let uses = model.usages(of: id)
        if !uses.isEmpty { parts.append("Used by: " + uses.prefix(8).joined(separator: ", ") + (uses.count > 8 ? "…" : "") + ". Those places will show an empty slot.") }
        parts.append("You can undo this with ⌘Z.")
        return parts.joined(separator: "\n\n")
    }

    private func open(_ id: Int) {
        model.designPath.append(design.kind(of: id) == .relation ? .relation(id) : .object(id))
    }

    @ViewBuilder private func menu(for id: Int) -> some View {
        let kind = design.kind(of: id)
        Button("Open") { open(id) }
        if kind != .user {
            Button("Rename…") { renaming = id }
            if [.template, .view, .abacus, .query, .index].contains(kind) {
                Button("Duplicate") {
                    if let new = model.editDesign("Duplicate", { $0.duplicate(id) }) { selection = new }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = id }
        }
    }

    private static let cell = CGSize(width: 96, height: 58)
    private static let margin: CGFloat = 40

    private var iconMode: some View {
        let items = icons
        let minV = items.map(\.v).min() ?? 0, minH = items.map(\.h).min() ?? 0
        let width = CGFloat((items.map(\.h).max() ?? 0) - minH) + Self.cell.width + Self.margin * 2
        let height = CGFloat((items.map(\.v).max() ?? 0) - minV) + Self.cell.height + Self.margin * 2
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.white.frame(width: width, height: height)
                    .onTapGesture { selection = nil }
                ForEach(items, id: \.objectID) { p in
                    let off = drag?.id == p.objectID ? drag!.offset : .zero
                    HelixIcon(objectID: p.objectID, design: design, selected: selection == p.objectID)
                        .frame(width: Self.cell.width, height: Self.cell.height, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(p.objectID) }
                        .simultaneousGesture(TapGesture().onEnded { selection = p.objectID })
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { g in selection = p.objectID; drag = (p.objectID, g.translation) }
                            .onEnded { g in
                                drag = nil
                                model.editDesign("Move Icon") {
                                    $0.moveIcon(p.objectID, inRelation: relationID, v: p.v + Int(g.translation.height),
                                                h: p.h + Int(g.translation.width))
                                }
                            })
                        .contextMenu { menu(for: p.objectID) }
                        .offset(x: CGFloat(p.h - minH) + 16 + Self.margin - Self.cell.width / 2 + off.width,
                                y: CGFloat(p.v - minV) + Self.margin + off.height)
                        .help(model.iconSummary(p.objectID))
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var listMode: some View {
        let rows = icons.map(\.objectID).sorted {
            ((design.kind(of: $0)?.rawValue ?? 0), (design.name(of: $0) ?? "").lowercased())
                < ((design.kind(of: $1)?.rawValue ?? 0), (design.name(of: $1) ?? "").lowercased())
        }.map(IdentifiedInt.init)
        return Table(rows, selection: $selection) {
            TableColumn("Kind") { r in
                Label(design.kind(of: r.id)?.displayName ?? "?", systemImage: HelixIcon.symbol(for: r.id, in: design))
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Name") { r in Text(design.name(of: r.id).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(r.id)") }
                .width(min: 120, ideal: 200)
            TableColumn("Content") { r in Text(model.iconSummary(r.id)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first { menu(for: id) }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
    }
}

struct IdentifiedInt: Identifiable, Hashable { let id: Int }

extension ObjectKind: Identifiable { public var id: UInt8 { rawValue } }

/// A 32×32 black-and-white icon with its name underneath, as in classic Helix.
struct HelixIcon: View {
    let objectID: Int
    let design: Design
    var selected = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: Self.symbol(for: objectID, in: design))
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected ? Color.white : Color.black)
                .frame(width: 34, height: 30)
                .background(selected ? Color.black : Color.clear, in: RoundedRectangle(cornerRadius: 3))
            Text(design.name(of: objectID).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(objectID)")
                .font(.system(size: 10))
                .foregroundStyle(selected ? Color.white : Color.black)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 2)
                .background(selected ? Color.black : Color.clear)
        }
    }

    static func symbol(for id: Int, in design: Design) -> String {
        switch design.kind(of: id) {
        case .relation: return "archivebox"
        case .field:
            switch design.field(id: id)?.type {
            case .number?: return "number.square"
            case .date?: return "calendar"
            case .flag?: return "flag"
            case .picture?: return "photo"
            default: return "character.textbox"
            }
        case .abacus: return "function"
        case .template: return "rectangle.3.group"
        case .view: return "macwindow"
        case .index: return "list.number"
        case .query: return "questionmark.square.dashed"
        case .user: return "person"
        case .menu: return "filemenu.and.selection"
        default: return "square.dashed"
        }
    }
}

extension CollectionModel {
    /// The "Content" column of RADE's list mode: a one-line summary of the icon.
    func iconSummary(_ id: Int) -> String {
        let d = design
        func name(_ id: Int?) -> String? { id.flatMap { d.name(of: $0) } }
        switch d.kind(of: id) {
        case .relation:
            guard let r = d.relation(id: id) else { return "" }
            return "\(baseRecords(r).records.count) records, \(r.fields.count) fields"
        case .field: return d.field(id: id)?.type.description ?? ""
        case .abacus: return d.formulaText(d.abacus(id: id)?.root)
        case .query: return d.formulaText(d.queryAbacusID(ofQuery: id).flatMap(d.abacus(id:))?.root)
        case .view:
            guard let v = d.view(id: id) else { return "" }
            return ["template: \(name(v.templateID) ?? "—")", name(v.queryID).map { "query: \($0)" },
                    name(v.indexID ?? v.defaultIndexID).map { "index: \($0)" }].compactMap { $0 }.joined(separator: ", ")
        case .template:
            guard let t = d.template(id: id) else { return "" }
            return "\(t.contentBounds.width)×\(t.contentBounds.height)" + (t.repeatElement != nil ? ", list" : ", form")
        case .index:
            return d.indexKeys(ofIndexObject: id).compactMap { d.name(of: $0) }.joined(separator: ", ")
        default:
            return d.kind(of: id)?.displayName ?? ""
        }
    }
}

// MARK: Sheets

struct RenameSheet: View {
    @State var name: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename").font(.headline)
            TextField("Name", text: $name).frame(width: 300).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        commit(n)
        dismiss()
    }
}

/// Creates a relation, field, abacus, template, view, query or index.
struct NewObjectSheet: View {
    @ObservedObject var model: CollectionModel
    let kind: ObjectKind
    let relationID: Int?
    let done: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Layout: String, CaseIterable, Identifiable {
        case form = "Form with all fields", list = "List with all fields", blank = "Blank"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var type: FieldType = .text
    @State private var layout: Layout = .form
    @State private var templateID: Int?
    @State private var keyID: Int?

    private var relation: Relation? { relationID.flatMap(model.design.relation(id:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(kind.displayName)").font(.headline)
            Form {
                TextField("Name", text: $name)
                switch kind {
                case .field:
                    Picker("Type", selection: $type) {
                        ForEach([FieldType.text, .number, .date, .flag, .picture], id: \.self) { Text($0.description).tag($0) }
                    }
                case .template:
                    Picker("Start with", selection: $layout) { ForEach(Layout.allCases) { Text($0.rawValue).tag($0) } }
                case .view:
                    Picker("Template", selection: $templateID) {
                        Text("None").tag(Int?.none)
                        ForEach(model.design.relationDesign(id: relationID ?? 0)?.templates ?? []) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                case .index:
                    Picker("Sort by", selection: $keyID) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(relation?.fields ?? []) { Text($0.displayName).tag(Int?.some($0.id)) }
                    }
                default:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { templateID = model.design.relationDesign(id: relationID ?? 0)?.templates.first?.id }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let rid = relationID ?? 0
        let fields = relation?.fields ?? []
        let id: Int? = model.editDesign("New \(kind.displayName)") { m in
            switch kind {
            case .relation: m.addRelation(name: n)
            case .field: m.addField(to: rid, name: n, type: type)
            case .abacus: m.addAbacus(to: rid, name: n, root: nil)
            case .template: m.addTemplate(to: rid, name: n, fields: layout == .blank ? [] : fields.filter { $0.type != .picture || layout == .form },
                                          list: layout == .list)
            case .view: m.addView(to: rid, name: n, templateID: templateID)
            case .query: m.addQuery(to: rid, name: n)
            case .index: m.addIndex(to: rid, name: n, keys: keyID.map { [$0] } ?? [])
            default: nil
            }
        }
        dismiss()
        done(id)
    }
}

// MARK: Editors

struct ObjectEditor: View {
    @ObservedObject var model: CollectionModel
    let objectID: Int

    var body: some View {
        let d = model.design
        let _ = model.revision
        Group {
            switch d.kind(of: objectID) {
            case .template: TemplateEditor(model: model, templateID: objectID)
            case .view: ViewEditor(model: model, viewID: objectID)
            case .abacus, .query: AbacusEditor(model: model, objectID: objectID)
            case .field: FieldEditor(model: model, fieldID: objectID)
            case .index: IndexEditor(model: model, indexID: objectID)
            case nil:
                ContentUnavailableView("Deleted", systemImage: "trash", description: Text("This item no longer exists. Undo (⌘Z) brings it back."))
            default:
                DesignObjectView(design: d, objectID: objectID).navigationTitle(d.name(of: objectID) ?? "")
            }
        }
    }
}

/// The spreadsheet-style record browser (not a Helix feature, but handy for checking data).
struct RecordsBrowser: View {
    @ObservedObject var model: CollectionModel
    let relationID: Int

    var body: some View {
        HSplitView {
            RecordsPane(model: model).frame(minWidth: 400)
            Group {
                if let rel = model.relation, let rec = model.selectedRecord {
                    RecordDetailView(relation: rel, record: rec)
                } else {
                    ContentUnavailableView("No Record Selected", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 280, idealWidth: 360)
        }
        .navigationTitle(model.relation.map { "\($0.name) — \(model.records.count) of \(model.totalRecordCount) records" } ?? "")
        .toolbar { ToolbarItem { HelpButton(topic: .records) } }
        .onAppear { model.select(.relation(relationID)) }
    }
}
