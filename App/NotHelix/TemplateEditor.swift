import HelixKit
import SwiftUI

/// Template layout editor: graph paper with the template's rectangles. Click to select, drag
/// to move, drag the corner handle to resize; the inspector edits the selected rectangle.
struct TemplateEditor: View {
    @ObservedObject var model: CollectionModel
    let templateID: Int

    @State private var selected: Int?
    @State private var moving: CGSize = .zero
    @State private var resizing: CGSize = .zero
    @FocusState private var canvasFocused: Bool

    private static let grid = 4

    private var design: Design { model.design }
    private var template: Template? { let _ = model.revision; return design.template(id: templateID) }
    private var relation: Relation? { design.relation(containing: templateID) }

    var body: some View {
        if let t = template, let rel = relation {
            HSplitView {
                canvas(t, rel).frame(minWidth: 420)
                TemplateInspector(model: model, templateID: templateID, selected: $selected)
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 360)
            }
            .navigationTitle("Template: \(t.name)")
            .toolbar { toolbar(t, rel) }
        } else {
            ContentUnavailableView("Template not found", systemImage: "rectangle.3.group")
        }
    }

    // MARK: Canvas

    private func canvas(_ t: Template, _ rel: Relation) -> some View {
        let b = t.contentBounds
        let size = CGSize(width: CGFloat(max(b.right + 200, t.page.width, 700)), height: CGFloat(max(b.bottom + 200, 500)))
        let flat = TemplateElement.flatten(t.elements)
        let context = TemplateContext(design: design, relation: rel, record: nil)
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                GraphPaper().frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil; canvasFocused = true }
                if let rep = t.repeatElement {
                    handle(for: rep, in: t) {
                        Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                            .overlay(alignment: .topLeading) {
                                Text("Repeat").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 3).background(Color.white).offset(x: 4, y: -7)
                            }
                    }
                }
                ForEach(flat) { e in
                    handle(for: e, in: t) {
                        TemplateElementView(element: atOrigin(e), context: context)
                            .frame(width: CGFloat(max(e.rect.width, 1)), height: CGFloat(max(e.rect.height, 1)), alignment: .topLeading)
                            .background(Color.white.opacity(0.001))
                            .overlay { if case .label = e.content { EmptyView() } else { Rectangle().strokeBorder(Color.black.opacity(0.25)) } }
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .padding()
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(white: 0.92))
        .environment(\.colorScheme, .light)
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard let id = selected else { return .ignored }
            let step = press.modifiers.contains(.shift) ? 10 : 1
            let (dx, dy): (Int, Int) = switch press.key {
            case .leftArrow: (-step, 0)
            case .rightArrow: (step, 0)
            case .upArrow: (0, -step)
            default: (0, step)
            }
            edit("Nudge") { $0.move(id, dx: dx, dy: dy) }
            return .handled
        }
        .onDeleteCommand { deleteSelected() }
    }

    /// The element moved to (0, 0): TemplateElementView positions by rect, the handle places it.
    private func atOrigin(_ e: TemplateElement) -> TemplateElement {
        var c = e
        c.rect = HelixRect(top: 0, left: 0, bottom: e.rect.height, right: e.rect.width)
        return c
    }

    /// Selection, drag-to-move and the resize handle around one rectangle.
    private func handle<Content: View>(for e: TemplateElement, in t: Template, @ViewBuilder content: () -> Content) -> some View {
        let isSel = selected == e.id
        let r = e.rect
        let w = CGFloat(max(r.width, 4)) + (isSel ? resizing.width : 0)
        let h = CGFloat(max(r.height, 4)) + (isSel ? resizing.height : 0)
        return content()
            .frame(width: w, height: h, alignment: .topLeading)
            .overlay {
                if isSel { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSel {
                    Rectangle().fill(Color.accentColor).frame(width: 9, height: 9).offset(x: 4, y: 4)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { resizing = $0.translation }
                            .onEnded { g in
                                resizing = .zero
                                let dw = snap(g.translation.width), dh = snap(g.translation.height)
                                edit("Resize Rectangle") { tt in
                                    tt.update(e.id) { el in
                                        el.rect = HelixRect(top: el.rect.top, left: el.rect.left,
                                                            bottom: max(el.rect.top + 8, el.rect.bottom + dh),
                                                            right: max(el.rect.left + 8, el.rect.right + dw))
                                    }
                                }
                            })
                        .help("Drag to resize")
                }
            }
            .contentShape(Rectangle())
            .offset(x: CGFloat(r.left) + (isSel ? moving.width : 0), y: CGFloat(r.top) + (isSel ? moving.height : 0))
            .onTapGesture { selected = e.id; canvasFocused = true }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { g in
                    if selected != e.id { selected = e.id }
                    moving = g.translation
                }
                .onEnded { g in
                    moving = .zero
                    let dx = snap(g.translation.width), dy = snap(g.translation.height)
                    if dx != 0 || dy != 0 { edit("Move Rectangle") { $0.move(e.id, dx: dx, dy: dy) } }
                    canvasFocused = true
                })
    }

    private func snap(_ v: CGFloat) -> Int { Int((v / CGFloat(Self.grid)).rounded()) * Self.grid }

    // MARK: Toolbar and edits

    @ToolbarContentBuilder
    private func toolbar(_ t: Template, _ rel: Relation) -> some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Label") { add(.label("Label")) }
                Menu("Field") {
                    ForEach(rel.fields) { f in Button(f.displayName) { add(.data(fieldObjectID: f.id, abacusObjectID: nil), labelled: f.displayName) } }
                }
                Menu("Abacus") {
                    ForEach(design.abaci(in: rel).filter { !$0.name.isEmpty }) { a in
                        Button(a.name) { add(.data(fieldObjectID: nil, abacusObjectID: a.id)) }
                    }
                }
                if t.repeatElement == nil {
                    Divider()
                    Button("Make List (Repeat Rectangle)") {
                        model.editDesign("Make List") { m in
                            guard var tt = m.relations.flatMap(\.templates).first(where: { $0.id == templateID }) else { return }
                            tt.makeList(id: m.allocateID())
                            m.setTemplate(tt)
                        }
                    }
                }
            } label: { Label("Add", systemImage: "plus.rectangle.on.rectangle") }
            .help("Add a label, field, abacus or repeat rectangle")
        }
        ToolbarItem {
            Button { duplicateSelected() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .disabled(selected == nil || selected == t.repeatElement?.id)
                .keyboardShortcut("d", modifiers: .command)
                .help("Duplicate the selected rectangle (⌘D)")
        }
        ToolbarItem {
            Button { deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                .disabled(selected == nil)
                .help("Delete the selected rectangle (⌫)")
        }
        ToolbarItem { HelpButton(topic: .template) }
    }

    private func edit(_ name: String, _ change: @escaping (inout Template) -> Void) {
        model.editDesign(name) { m in
            guard var t = m.relations.flatMap(\.templates).first(where: { $0.id == templateID }) else { return }
            change(&t)
            m.setTemplate(t)
        }
    }

    private func add(_ content: TemplateElement.Content, labelled label: String? = nil) {
        guard let t = template else { return }
        let top = t.contentBounds.bottom + 12
        var newSelection: Int?
        model.editDesign("Add Rectangle") { m in
            guard var tt = m.relations.flatMap(\.templates).first(where: { $0.id == templateID }) else { return }
            let font = HelixFont(family: "Lucida Grande", size: 13, style: 0)
            var x = 10
            if let label {
                tt.insert(TemplateElement(id: m.allocateID(), rect: HelixRect(top: top, left: 10, bottom: top + 22, right: 150),
                                          font: HelixFont(family: "Palatino", size: 14, style: 1), alignment: .left,
                                          tabOrder: 0, content: .label(label + ":")))
                x = 160
            }
            let isLabel: Bool = { if case .label = content { true } else { false } }()
            let id = m.allocateID()
            tt.insert(TemplateElement(id: id, rect: HelixRect(top: top, left: x, bottom: top + 22, right: x + (isLabel ? 120 : 300)),
                                      font: isLabel ? HelixFont(family: "Palatino", size: 14, style: 1) : font, alignment: .left,
                                      tabOrder: TemplateElement.flatten(tt.elements).count, content: content))
            m.setTemplate(tt)
            newSelection = id
        }
        selected = newSelection
    }

    private func deleteSelected() {
        guard let id = selected else { return }
        edit("Delete Rectangle") { $0.remove(id) }
        selected = nil
    }

    private func duplicateSelected() {
        guard let id = selected, let e = template?.element(id) else { return }
        var newSelection: Int?
        model.editDesign("Duplicate Rectangle") { m in
            guard var tt = m.relations.flatMap(\.templates).first(where: { $0.id == templateID }) else { return }
            var copy = e
            copy.id = m.allocateID()
            copy.rect = e.rect.offsetBy(dx: 12, dy: 12)
            tt.insert(copy)
            m.setTemplate(tt)
            newSelection = copy.id
        }
        selected = newSelection
    }
}

// MARK: Inspector

struct TemplateInspector: View {
    @ObservedObject var model: CollectionModel
    let templateID: Int
    @Binding var selected: Int?

    private var design: Design { model.design }

    var body: some View {
        let _ = model.revision
        if let t = design.template(id: templateID), let rel = design.relation(containing: templateID) {
            Form {
                if let id = selected, let e = t.element(id) {
                    elementSection(e, rel)
                } else {
                    Section("Template") {
                        NameField(title: "Name", name: t.name) { n in model.editDesign("Rename Template") { $0.rename(templateID, to: n) } }
                        LabeledContent("Kind", value: t.repeatElement == nil ? "Form (one record)" : "List (repeat rectangle)")
                        LabeledContent("Rectangles", value: "\(TemplateElement.flatten(t.elements).count)")
                        LabeledContent("Content size", value: "\(t.contentBounds.width) × \(t.contentBounds.height)")
                    }
                    Section {
                        Text("Click a rectangle to edit it. Use Add in the toolbar for labels, fields and abaci.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private func elementSection(_ e: TemplateElement, _ rel: Relation) -> some View {
        switch e.content {
        case .label(let text):
            Section("Label") {
                LabelTextEditor(text: text) { new in set(e, "Edit Label") { $0.content = .label(new) } }
            }
        case .data(let fid, let aid):
            Section("Data rectangle") {
                Picker("Field", selection: Binding(get: { fid }, set: { new in set(e, "Change Field") { $0.content = .data(fieldObjectID: new, abacusObjectID: aid) } })) {
                    Text("None").tag(Int?.none)
                    ForEach(rel.fields) { Text($0.displayName).tag(Int?.some($0.id)) }
                }
                Picker("Abacus", selection: Binding(get: { aid }, set: { new in set(e, "Change Abacus") { $0.content = .data(fieldObjectID: fid, abacusObjectID: new) } })) {
                    Text("None").tag(Int?.none)
                    ForEach(design.abaci(in: rel).filter { !$0.name.isEmpty }) { Text($0.name).tag(Int?.some($0.id)) }
                }
                Text(fid != nil && aid != nil ? "The abacus gives the field its default value in new records." : "")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Vertical scroll bar", isOn: bind(e, \.scrollsVertically, "Change Scroll Bar"))
                Toggle("Currency (e.g. 3.319Pts)", isOn: Binding(get: { e.format.currency }, set: { on in
                    set(e, "Change Format") { $0.format = NumberFormat(kind: 1, flags: on ? 0x80 : ($0.format.flags & 0x40), decimals: $0.format.decimals) }
                }))
                Stepper("Decimals: \(e.format.isCustom ? "\(e.format.decimals)" : "auto")", onIncrement: {
                    set(e, "Change Format") { $0.format = NumberFormat(kind: 1, flags: $0.format.flags | 0x40, decimals: min(6, $0.format.decimals + ($0.format.isCustom ? 1 : 0))) }
                }, onDecrement: {
                    set(e, "Change Format") {
                        $0.format = $0.format.decimals == 0 ? NumberFormat(kind: 1, flags: $0.format.flags & 0x80, decimals: 0)
                            : NumberFormat(kind: 1, flags: $0.format.flags | 0x40, decimals: $0.format.decimals - 1)
                    }
                })
            }
        case .repeatGroup, .group:
            Section("Repeat rectangle") {
                Text("Everything inside repeats once per record in list views. Drag fields into it; move it to move its contents.")
                    .foregroundStyle(.secondary)
            }
        }
        if !isGroup(e) {
            Section("Text") {
                Picker("Font", selection: Binding(get: { e.font.family ?? "" }, set: { new in set(e, "Change Font") { $0.font.family = new.isEmpty ? nil : new } })) {
                    Text("System").tag("")
                    ForEach(fontChoices(e), id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(e.font.size)", value: Binding(get: { e.font.size }, set: { v in set(e, "Change Size") { $0.font.size = v } }), in: 6...72)
                HStack {
                    styleToggle(e, 1, "bold")
                    styleToggle(e, 2, "italic")
                    styleToggle(e, 4, "underline")
                    Spacer()
                    Picker("", selection: Binding(get: { e.alignment }, set: { a in set(e, "Change Alignment") { $0.alignment = a } })) {
                        Image(systemName: "text.alignleft").tag(HelixAlignment.left)
                        Image(systemName: "text.aligncenter").tag(HelixAlignment.center)
                        Image(systemName: "text.alignright").tag(HelixAlignment.right)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Toggle("Frame", isOn: bind(e, \.framed, "Change Frame"))
                colorRow("Text colour", e.textColor, default: .black) { hex in set(e, "Change Colour") { $0.textColor = hex } }
                colorRow("Background", e.backgroundColor, default: .white) { hex in set(e, "Change Colour") { $0.backgroundColor = hex } }
            }
        }
        Section("Position and size") {
            numberRow("Left", e.rect.left) { v in set(e, "Move Rectangle") { $0.rect = $0.rect.offsetBy(dx: v - $0.rect.left) } }
            numberRow("Top", e.rect.top) { v in set(e, "Move Rectangle") { $0.rect = $0.rect.offsetBy(dy: v - $0.rect.top) } }
            numberRow("Width", e.rect.width) { v in set(e, "Resize Rectangle") { $0.rect.right = $0.rect.left + max(8, v) } }
            numberRow("Height", e.rect.height) { v in set(e, "Resize Rectangle") { $0.rect.bottom = $0.rect.top + max(8, v) } }
        }
        Section {
            Button("Delete Rectangle", role: .destructive) {
                let id = e.id
                edit("Delete Rectangle") { $0.remove(id) }
                selected = nil
            }
        }
    }

    private func colorRow(_ title: String, _ hex: String?, default def: Color, commit: @escaping (String?) -> Void) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { Color(hex: hex) ?? def }, set: { commit($0.hex) }), supportsOpacity: false)
            if hex != nil {
                Button { commit(nil) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("No colour")
            }
        }
    }

    private func isGroup(_ e: TemplateElement) -> Bool {
        if case .repeatGroup = e.content { true } else if case .group = e.content { true } else { false }
    }

    private func fontChoices(_ e: TemplateElement) -> [String] {
        var names = design.fontTable.filter { !$0.isEmpty }
        for n in ["Lucida Grande", "Palatino", "Times New Roman", "Helvetica", "Helvetica Neue", "Geneva", "Georgia", "Avenir Next"]
        where !names.contains(n) { names.append(n) }
        if let f = e.font.family, !names.contains(f) { names.insert(f, at: 0) }
        return names
    }

    private func styleToggle(_ e: TemplateElement, _ bit: UInt8, _ symbol: String) -> some View {
        Toggle(isOn: Binding(get: { e.font.style & bit != 0 }, set: { on in
            set(e, "Change Style") { $0.font.style = on ? $0.font.style | bit : $0.font.style & ~bit }
        })) { Image(systemName: symbol) }
        .toggleStyle(.button)
    }

    private func numberRow(_ title: String, _ value: Int, _ commit: @escaping (Int) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: { if $0 != value { commit($0) } }), format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .labelsHidden()
        }
    }

    private func bind(_ e: TemplateElement, _ path: WritableKeyPath<TemplateElement, Bool>, _ name: String) -> Binding<Bool> {
        Binding(get: { e[keyPath: path] }, set: { v in set(e, name) { $0[keyPath: path] = v } })
    }

    private func set(_ e: TemplateElement, _ name: String, _ change: @escaping (inout TemplateElement) -> Void) {
        let id = e.id
        edit(name) { $0.update(id, change) }
    }

    private func edit(_ name: String, _ change: @escaping (inout Template) -> Void) {
        model.editDesign(name) { m in
            guard var t = m.relations.flatMap(\.templates).first(where: { $0.id == templateID }) else { return }
            change(&t)
            m.setTemplate(t)
        }
    }
}

/// Multi-line label text that saves when focus leaves (one undo step per edit).
struct LabelTextEditor: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Text", text: $draft, axis: .vertical)
            .lineLimit(1...6)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { if !focused { draft = text } }
            .onChange(of: focused) { if !focused, draft != text { commit(draft) } }
            .onSubmit { if draft != text { commit(draft) } }
    }
}
