import HelixKit
import SwiftUI

/// Name field that saves when you press Return or leave it.
struct NameField: View {
    let title: String
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = name }
            .onChange(of: name) { if !focused { text = name } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != name { commit(t) } else { text = name }
    }
}

// MARK: Field

struct FieldEditor: View {
    @ObservedObject var model: CollectionModel
    let fieldID: Int

    var body: some View {
        let d = model.design
        if let f = d.field(id: fieldID) {
            Form {
                Section {
                    NameField(title: "Name", name: f.name) { n in model.editDesign("Rename Field") { $0.rename(fieldID, to: n) } }
                    Picker("Type", selection: Binding(get: { f.type }, set: { t in
                        var g = f
                        g.type = t
                        model.editDesign("Change Field Type") { $0.setField(g) }
                    })) {
                        ForEach([FieldType.text, .number, .date, .flag, .picture], id: \.self) { Text($0.description).tag($0) }
                    }
                } header: { Text("Field") } footer: {
                    Text("Changing the type does not convert values already entered.").foregroundStyle(.secondary)
                }
                Section("Details") {
                    LabeledContent("Field number", value: "\(f.fieldID)")
                    LabeledContent("Relation", value: d.relation(containing: fieldID)?.name ?? "")
                    if let c = f.created { LabeledContent("Created in Helix", value: c.description) }
                    if let m = f.modified { LabeledContent("Modified in Helix", value: m.description) }
                }
                Section("Used by") {
                    let uses = model.usages(of: fieldID)
                    if uses.isEmpty {
                        Text("Not used on any template, abacus or index yet. Open a template and choose Add ▸ Field to show it on a form.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(uses, id: \.self) { Text($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Field: \(f.displayName)")
            .toolbar { ToolbarItem { HelpButton(topic: .field) } }
        }
    }
}

// MARK: View

struct ViewEditor: View {
    @ObservedObject var model: CollectionModel
    let viewID: Int

    var body: some View {
        let d = model.design
        if let v = d.view(id: viewID), let rel = d.relation(containing: viewID), let rd = d.relationDesign(id: rel.id) {
            VSplitView {
                Form {
                    Section {
                        NameField(title: "Name", name: v.name) { n in model.editDesign("Rename View") { $0.rename(viewID, to: n) } }
                        Picker("Template", selection: binding(v, \.templateID)) {
                            Text("None").tag(Int?.none)
                            ForEach(rd.templates) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                        Picker("Query", selection: binding(v, \.queryID)) {
                            Text("All records").tag(Int?.none)
                            ForEach(rd.queries) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                        Picker("Sort order", selection: binding(v, \.indexID)) {
                            Text("Record number").tag(Int?.none)
                            ForEach(rd.indexes) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                    } header: { Text("View") }
                    Section {
                        Button("Open in User Mode") {
                            model.openViewID = viewID
                            model.mode = .user
                        }
                        OpenInWindowButton(model: model, viewID: viewID)
                    }
                }
                .formStyle(.grouped)
                .frame(minHeight: 260, idealHeight: 300)
                Group {
                    if let t = model.template(for: v), let ev = model.evaluator(for: v) {
                        HelixViewPane(view: v, template: t, design: d, relation: rel, records: ev.records, evaluator: ev,
                                      actions: nil, sort: nil, currentIndex: model.recordIndexBinding(for: v))
                    } else {
                        ContentUnavailableView("No Template", systemImage: "rectangle.3.group",
                                               description: Text("Pick a template to see the view."))
                    }
                }
                .frame(minHeight: 200)
            }
            .navigationTitle("View: \(v.name)")
            .toolbar { ToolbarItem { HelpButton(topic: .view) } }
        }
    }

    private func binding(_ v: ViewDefinition, _ path: WritableKeyPath<ViewDefinition, Int?>) -> Binding<Int?> {
        Binding(get: { v[keyPath: path] }, set: { new in
            var w = v
            w[keyPath: path] = new
            if path == \.indexID { w.defaultIndexID = new }
            model.editDesign("Change View") { $0.setView(w) }
        })
    }
}

// MARK: Index

struct IndexEditor: View {
    @ObservedObject var model: CollectionModel
    let indexID: Int

    var body: some View {
        let d = model.design
        if let x = d.index(id: indexID), let rel = d.relation(containing: indexID) {
            Form {
                Section("Index") {
                    NameField(title: "Name", name: x.name) { n in model.editDesign("Rename Index") { $0.rename(indexID, to: n) } }
                }
                Section {
                    if x.keys.isEmpty { Text("No keys yet — records stay in record-number order.").foregroundStyle(.secondary) }
                    ForEach(Array(x.keys.enumerated()), id: \.offset) { i, key in
                        HStack {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: HelixIcon.symbol(for: key, in: d))
                            Text(d.name(of: key) ?? "(deleted)")
                            Spacer()
                            Button { move(x, i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                            Button { move(x, i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == x.keys.count - 1)
                            Button { set(x, x.keys.enumerated().filter { $0.offset != i }.map(\.element)) } label: {
                                Image(systemName: "minus.circle")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    Menu("Add Key") {
                        Section("Fields") {
                            ForEach(rel.fields.filter { !x.keys.contains($0.id) }) { f in Button(f.displayName) { set(x, x.keys + [f.id]) } }
                        }
                        Section("Abaci") {
                            ForEach(d.abaci(in: rel).filter { !$0.name.isEmpty && !x.keys.contains($0.id) }) { a in
                                Button(a.name) { set(x, x.keys + [a.id]) }
                            }
                        }
                    }
                } header: { Text("Sort by") } footer: {
                    Text(x.helixNumber != nil
                         ? "Uses the exact order saved in the Helix file until you change the keys."
                         : "Records are sorted by the first key, then the next one breaks ties.")
                        .foregroundStyle(.secondary)
                }
                Section("Used by") {
                    let uses = model.usages(of: indexID)
                    if uses.isEmpty { Text("No view uses this index yet.").foregroundStyle(.secondary) }
                    ForEach(uses, id: \.self) { Text($0) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Index: \(x.name)")
            .toolbar { ToolbarItem { HelpButton(topic: .index) } }
        }
    }

    private func set(_ x: IndexDesign, _ keys: [Int]) {
        var y = x
        y.keys = keys
        model.editDesign("Change Index") { $0.setIndex(y) }
    }

    private func move(_ x: IndexDesign, _ i: Int, _ by: Int) {
        var k = x.keys
        k.swapAt(i, i + by)
        set(x, k)
    }
}

// MARK: Abacus and query

/// Formula editor for abaci and queries: type the formula, see it checked, previewed and
/// drawn as Helix tiles, then Apply.
struct AbacusEditor: View {
    @ObservedObject var model: CollectionModel
    let objectID: Int

    @State private var text = ""
    @State private var loadedFor: Int?

    private var design: Design { model.design }
    private var isQuery: Bool { design.kind(of: objectID) == .query }
    private var abacusID: Int? { isQuery ? design.queryAbacusID(ofQuery: objectID) : objectID }
    private var relation: Relation? { design.relation(containing: objectID) }
    private var saved: String { design.formulaText(abacusID.flatMap(design.abacus(id:))?.root) }

    private var parsed: Result<Tile?, Formula.ParseError> {
        guard let rel = relation else { return .success(nil) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success(nil) }
        do { return .success(try design.parseFormula(text, in: rel)) } catch let e as Formula.ParseError { return .failure(e) } catch {
            return .failure(Formula.ParseError(message: error.localizedDescription, offset: 0))
        }
    }

    var body: some View {
        let result = parsed
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                NameField(title: "Name", name: design.name(of: objectID) ?? "") { n in
                    model.editDesign(isQuery ? "Rename Query" : "Rename Abacus") { $0.rename(objectID, to: n) }
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                Spacer()
                insertMenus
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, idealHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
            HStack {
                switch result {
                case .success(let t):
                    Label(t == nil ? "Empty — the abacus has no value." : "Formula OK", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let e):
                    Label(e.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                Button("Revert") { text = saved }.disabled(text == saved)
                Button("Apply", action: apply)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text == saved || (try? result.get()) == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.callout)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 14) {
                    preview(result)
                    if case .success(let t?) = result {
                        Text("Tiles").font(.caption.bold()).foregroundStyle(.secondary)
                        TileView(tile: t, design: design)
                    }
                }
                .padding(.bottom, 20)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .padding(16)
        .navigationTitle("\(isQuery ? "Query" : "Abacus"): \(design.name(of: objectID).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(objectID)")")
        .toolbar { ToolbarItem { HelpButton(topic: isQuery ? .query : .abacus) } }
        .onAppear(perform: load)
        .onChange(of: objectID) { load() }
    }

    private func load() {
        guard loadedFor != objectID else { return }
        loadedFor = objectID
        text = saved
    }

    private var insertMenus: some View {
        HStack {
            Menu("Field") {
                ForEach(relation?.fields ?? []) { f in Button(f.displayName) { insert("[\(f.name)]") } }
            }
            Menu("Abacus") {
                ForEach(relation.map { design.abaci(in: $0) }?.filter { !$0.name.isEmpty && $0.id != abacusID } ?? []) { a in
                    Button(a.name) { insert("{\(a.name)}") }
                }
            }
            Menu("Function") {
                Button("if … then … else …") { insert("if  then  else ") }
                ForEach(Formula.functionNames, id: \.self) { n in Button(n) { insert(n) } }
            }
            Menu("Operator") {
                ForEach(Formula.operatorSymbols, id: \.self) { s in Button(s) { insert(" \(s) ") } }
            }
        }
        .fixedSize()
    }

    private func insert(_ s: String) {
        if !text.isEmpty, !text.hasSuffix(" "), !s.hasPrefix(" ") { text += " " }
        text += s
    }

    private func apply() {
        guard let rel = relation else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tile = trimmed.isEmpty ? Optional<Tile>.none : (try? design.parseFormula(text, in: rel)) else { return }
        model.editDesign(isQuery ? "Edit Query" : "Edit Abacus") { m in
            var aid = abacusID
            if aid == nil, isQuery, let new = m.addAbacus(to: rel.id, name: "", root: nil, showIcon: false) {
                aid = new
                if var q = m.relations.flatMap(\.queries).first(where: { $0.id == objectID }) { q.abacusID = new; m.setQuery(q) }
            }
            guard let aid, let old = m.relations.flatMap(\.abaci).first(where: { $0.id == aid }) else { return }
            m.setAbacus(Abacus(id: aid, name: old.name, root: tile))
        }
        text = saved
    }

    /// Results with the edited (unsaved) formula: values for the first records, or the query's count.
    @ViewBuilder private func preview(_ result: Result<Tile?, Formula.ParseError>) -> some View {
        if let rel = relation, case .success(let tile) = result {
            let temp = Design(model: design.model, collection: design.collection)
            let aid: Int? = temp.update { m in
                if let aid = abacusID, let old = m.relations.flatMap(\.abaci).first(where: { $0.id == aid }) {
                    m.setAbacus(Abacus(id: aid, name: old.name, root: tile))
                    return aid
                }
                return m.addAbacus(to: rel.id, name: "", root: tile, showIcon: false)
            }
            let records = model.baseRecords(rel).records
            let ev = AbacusEvaluator(design: temp, relation: rel, records: records)
            if isQuery, let aid {
                let n = records.filter { if case .flag(true)? = ev.value(ofAbacus: aid, for: $0) { true } else { false } }.count
                Label("\(n) of \(records.count) records match", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
            } else if let aid {
                Text("Result for the first records").font(.caption.bold()).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(records.prefix(6)) { r in
                        GridRow {
                            Text(model.label(for: r, in: rel)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 320, alignment: .leading)
                            Text(ev.value(ofAbacus: aid, for: r).map { $0.description.replacingOccurrences(of: "\n", with: " ⏎ ") } ?? "—")
                                .lineLimit(2)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }
}

struct TileView: View {
    let tile: Tile
    let design: Design

    var body: some View {
        switch tile {
        case .field(let id):
            chip(design.name(of: id) ?? "(deleted)", symbol: "character.textbox")
        case .abacus(let id):
            chip(design.name(of: id) ?? "(deleted)", symbol: "function")
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
                            AnyView(TileView(tile: arg, design: design))
                        }
                    }
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.6), lineWidth: 1))
        }
    }

    private func chip(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            Text(text).font(.system(size: 11))
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(symbol == nil ? Color.secondary.opacity(0.12) : Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.5), lineWidth: 1))
    }
}

struct OpenInWindowButton: View {
    @ObservedObject var model: CollectionModel
    let viewID: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open in New Window") { openWindow(id: "view", value: ViewWindowRef(modelID: model.id, viewID: viewID)) }
    }
}
