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
            IconDesktop(model: model, title: model.collection.name, icons: model.collection.icons) { id in
                model.designPath.append(model.collection.objects[id]?.kind == .relation ? .relation(id) : .object(id))
            }
            .navigationDestination(for: DesignRoute.self) { route in
                destination(route)
            }
        }
    }

    @ViewBuilder private func destination(_ route: DesignRoute) -> some View {
        switch route {
        case .relation(let id):
            if let rel = model.collection.relations.first(where: { $0.id == id }) {
                IconDesktop(model: model, title: rel.name, icons: rel.icons) { model.designPath.append(.object($0)) }
                    .toolbar {
                        ToolbarItem {
                            Button { model.designPath.append(.records(id)) } label: {
                                Label("Browse Records", systemImage: "tablecells")
                            }
                            .help("Browse all \(rel.recordCount) records of \(rel.name) in a table")
                        }
                    }
            }
        case .records(let id):
            RecordsBrowser(model: model, relationID: id)
        case .object(let id):
            ObjectEditor(model: model, objectID: id)
        }
    }
}

// MARK: Icon desktop

/// A collection or relation window in RADE style: icons at their saved positions, or a list.
struct IconDesktop: View {
    @ObservedObject var model: CollectionModel
    let title: String
    let icons: [IconPlacement]
    let open: (Int) -> Void

    @AppStorage("iconDisplayMode") private var displayMode: IconDisplayMode = .icon
    @State private var selection: Int?

    private var placed: [(IconPlacement, DesignObject)] {
        icons.compactMap { p in model.collection.objects[p.objectID].map { (p, $0) } }
    }

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
                Picker("Display", selection: $displayMode) {
                    ForEach(IconDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Display icons at their positions, or as a list")
            }
        }
    }

    private static let cell = CGSize(width: 96, height: 58)
    private static let margin: CGFloat = 40

    private var iconMode: some View {
        let items = placed
        let minV = items.map(\.0.v).min() ?? 0, minH = items.map(\.0.h).min() ?? 0
        let width = CGFloat((items.map(\.0.h).max() ?? 0) - minH) + Self.cell.width + Self.margin * 2
        let height = CGFloat((items.map(\.0.v).max() ?? 0) - minV) + Self.cell.height + Self.margin * 2
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.white.frame(width: width, height: height)
                    .onTapGesture { selection = nil }
                ForEach(items, id: \.1.id) { p, obj in
                    HelixIcon(object: obj, collection: model.collection, selected: selection == obj.id)
                        .frame(width: Self.cell.width, height: Self.cell.height, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(obj.id) }
                        .simultaneousGesture(TapGesture().onEnded { selection = obj.id })
                        .offset(x: CGFloat(p.h - minH) + 16 + Self.margin - Self.cell.width / 2, y: CGFloat(p.v - minV) + Self.margin)
                        .help(model.iconSummary(obj))
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var listMode: some View {
        let rows = placed.map(\.1).sorted {
            ($0.rawKind, $0.name.lowercased()) < ($1.rawKind, $1.name.lowercased())
        }
        return Table(rows, selection: $selection) {
            TableColumn("Kind") { obj in
                Label(obj.kind?.displayName ?? "Kind \(obj.rawKind)", systemImage: HelixIcon.symbol(for: obj, in: model.collection))
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Name") { obj in Text(obj.name.isEmpty ? "#\(obj.id)" : obj.name) }
                .width(min: 120, ideal: 200)
            TableColumn("Content") { obj in Text(model.iconSummary(obj)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
    }
}

/// A 32×32 black-and-white icon with its name underneath, as in classic Helix.
struct HelixIcon: View {
    let object: DesignObject
    let collection: HelixCollection
    var selected = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: Self.symbol(for: object, in: collection))
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected ? Color.white : Color.black)
                .frame(width: 34, height: 30)
                .background(selected ? Color.black : Color.clear, in: RoundedRectangle(cornerRadius: 3))
            Text(object.name.isEmpty ? "#\(object.id)" : object.name)
                .font(.system(size: 10))
                .foregroundStyle(selected ? Color.white : Color.black)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 2)
                .background(selected ? Color.black : Color.clear)
        }
    }

    static func symbol(for obj: DesignObject, in collection: HelixCollection) -> String {
        switch obj.kind {
        case .relation: return "archivebox"
        case .field:
            let type = collection.relations.lazy.flatMap(\.fields).first { $0.id == obj.id }?.type
            switch type {
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
    func iconSummary(_ obj: DesignObject) -> String {
        func name(_ id: Int?) -> String? { id.flatMap { collection.objects[$0]?.name } }
        switch obj.kind {
        case .relation:
            return collection.relations.first { $0.id == obj.id }.map { "\($0.recordCount) records, \($0.fields.count) fields" } ?? ""
        case .field:
            return collection.relations.lazy.flatMap(\.fields).first { $0.id == obj.id }?.type.description ?? ""
        case .abacus:
            return collection.formulaText(collection.abacus(id: obj.id)?.root)
        case .query:
            return collection.formulaText(collection.queryAbacusID(ofQuery: obj.id).flatMap(collection.abacus(id:))?.root)
        case .view:
            guard let v = collection.view(id: obj.id) else { return "" }
            return ["template: \(name(v.templateID) ?? "—")", name(v.queryID).map { "query: \($0)" },
                    name(v.indexID ?? v.defaultIndexID).map { "index: \($0)" }].compactMap { $0 }.joined(separator: ", ")
        case .template:
            guard let t = cachedTemplate(id: obj.id) else { return "" }
            return "\(t.contentBounds.width)×\(t.contentBounds.height)" + (t.repeatElement != nil ? ", list" : ", form")
        case .index:
            return collection.indexNumber(ofIndexObject: obj.id).map { "index #\($0)" } ?? ""
        default:
            return obj.kind?.displayName ?? ""
        }
    }
}

// MARK: Icon editors

struct ObjectEditor: View {
    @ObservedObject var model: CollectionModel
    let objectID: Int

    var body: some View {
        let c = model.collection
        if let obj = c.objects[objectID] {
            switch obj.kind {
            case .template:
                if let t = model.cachedTemplate(id: obj.id), let rel = model.relationContaining(obj.id) {
                    TemplateDesignView(template: t, context: TemplateContext(collection: c, relation: rel, record: nil))
                } else {
                    DesignObjectView(collection: c, object: obj)
                }
            case .view:
                if let v = c.view(id: obj.id), let rel = model.relation(ofView: v), let t = model.template(for: v),
                   let ev = model.evaluator(for: v) {
                    HelixViewPane(view: v, template: t, collection: c, relation: rel, records: ev.records, evaluator: ev,
                                  actions: model.actions(for: v), sort: model.sortControl(for: v), currentIndex: model.recordIndexBinding(for: v))
                } else {
                    DesignObjectView(collection: c, object: obj)
                }
            case .abacus, .query:
                AbacusEditor(model: model, object: obj)
            default:
                DesignObjectView(collection: c, object: obj).navigationTitle(obj.name)
            }
        }
    }
}

/// Abacus editor: the formula as nested tiles, like Helix's tile-based editor.
struct AbacusEditor: View {
    @ObservedObject var model: CollectionModel
    let object: DesignObject

    var body: some View {
        let c = model.collection
        let abacus = c.abacus(id: object.id) ?? c.queryAbacusID(ofQuery: object.id).flatMap(c.abacus(id:))
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 16) {
                if let root = abacus?.root {
                    TileView(tile: root, collection: c)
                } else {
                    Text("This abacus has no tiles.").foregroundStyle(.secondary)
                }
                GroupBox("As text") {
                    Text(c.formulaText(abacus?.root))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: 700, alignment: .leading)
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(.topLeading)
        .background(GraphPaper().background(Color.white))
        .environment(\.colorScheme, .light)
        .navigationTitle("\(object.kind == .query ? "Query" : "Abacus"): \(object.name.isEmpty ? "#\(object.id)" : object.name)")
    }
}

struct TileView: View {
    let tile: Tile
    let collection: HelixCollection

    var body: some View {
        switch tile {
        case .field(let id):
            chip(collection.objects[id]?.name ?? "?", symbol: "character.textbox")
        case .abacus(let id):
            chip(collection.objects[id]?.name ?? "?", symbol: "function")
        case .constant(let v):
            chip(v.map { if case .text(let s) = $0 { "\"\(s.replacingOccurrences(of: "\n", with: "⏎"))\"" } else { $0.description } } ?? "?",
                 symbol: nil)
        case .empty:
            RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: 28, height: 22)
        case .op(let op, let args, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(op.description).font(.system(size: 11, weight: .semibold))
                if !args.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(Array(args.enumerated()), id: \.offset) { _, arg in
                            AnyView(TileView(tile: arg, collection: collection))
                        }
                    }
                }
            }
            .padding(6)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black, lineWidth: 1))
        }
    }

    private func chip(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            Text(text).font(.system(size: 11))
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(symbol == nil ? Color(white: 0.93) : Color.white)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
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
        .onAppear { model.select(.relation(relationID)) }
    }
}
