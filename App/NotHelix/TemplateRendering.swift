import AppKit
import HelixKit
import SwiftUI

/// Everything needed to fill a template's rectangles.
struct TemplateContext {
    let design: Design
    let relation: Relation
    /// nil renders the template in design style (icon names instead of data).
    let record: Record?
    var evaluator: AbacusEvaluator?
    /// When set, field rectangles are editable.
    var editor: FieldEditing?
    /// When set (lists in Browse mode), data rectangles are clickable.
    var onActivate: ((TemplateElement) -> Void)?
    /// Rendering for print/PDF: no scroll views (they cannot be drawn off screen).
    var forPrint = false

    func editableField(for element: TemplateElement) -> Field? {
        guard editor != nil, record != nil, case .data(let fid?, _) = element.content,
              let field = relation.field(objectID: fid) else { return nil }
        return field
    }

    func text(for element: TemplateElement) -> (String, placeholder: Bool)? {
        guard case .data(let fid, let aid) = element.content else { return nil }
        if let record {
            if let fid, let field = relation.field(objectID: fid), let v = record[field] { return (display(v, element), false) }
            if fid == nil, let aid {
                guard let evaluator else { return (design.name(of: aid) ?? "", true) }
                return (evaluator.value(ofAbacus: aid, for: record).map { display($0, element) } ?? "", false)
            }
            return ("", false)
        }
        return ([fid, aid].compactMap { $0.flatMap { design.name(of: $0) } }.joined(separator: " / "), true)
    }

    /// A value as the rectangle's format shows it (numbers use the Helix number format and region).
    func display(_ v: Value, _ element: TemplateElement) -> String {
        guard case .number(let n) = v else { return v.description }
        return element.format.string(n, locale: HelixRegion.locale, currencySymbol: HelixRegion.currencySymbol)
    }

    func value(for element: TemplateElement) -> Value? {
        guard let record, case .data(let fid, let aid) = element.content else { return nil }
        if let fid, let field = relation.field(objectID: fid) { return record[field] }
        return aid.flatMap { evaluator?.value(ofAbacus: $0, for: record) }
    }
}

/// Regional number settings. Helix used the Mac's region; these collections were made in Spanish,
/// so that is the default (Settings ▸ Numbers can change it).
enum HelixRegion {
    static var locale: Locale { Locale(identifier: UserDefaults.standard.string(forKey: "numberLocale") ?? "es_ES") }
    static var currencySymbol: String { UserDefaults.standard.string(forKey: "currencySymbol") ?? "Pts" }
}

/// Draft storage for a record being edited on a form.
struct FieldEditing {
    var changed: (Field) -> Bool = { _ in false }
    let text: (Field) -> String
    let setText: (Field, String) -> Void
    let flag: (Field) -> Bool
    let setFlag: (Field, Bool) -> Void
    var picture: (Field) -> Data? = { _ in nil }
    var setPicture: (Field, Data?) -> Void = { _, _ in }
}

/// A picture field on a form: drop, paste or choose an image; it is stored as PNG.
struct PictureWell: View {
    let image: Data?
    let changed: Bool
    let set: (Data?) -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            if let image, let ns = NSImage(data: image) {
                Image(nsImage: ns).resizable().scaledToFit()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus").font(.title2)
                    Text("Drop or paste a picture").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.15) : changed ? Color.orange.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onDrop(of: [.image, .fileURL], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { DispatchQueue.main.async { set(Self.png(img)) } }
                }
                return true
            }
            return false
        }
        .contextMenu {
            Button("Choose Picture…", action: choose)
            Button("Paste") { if let img = NSImage(pasteboard: .general) { set(Self.png(img)) } }
            if image != nil { Button("Remove Picture", role: .destructive) { set(nil) } }
        }
        .onTapGesture(count: 2, perform: choose)
        .help("Drop, paste (right-click) or double-click to choose a picture")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        set(Self.png(img))
    }

    /// PNG data, scaled down so the longest side is at most 1600 pixels.
    static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1600 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

/// Text used to edit a stored value (dates as d-m-yyyy, numbers without grouping).
func editingText(_ v: Value?) -> String {
    switch v {
    case .number(let n)?: n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    case let v?: v.description
    case nil: ""
    }
}

struct EditableText: View {
    let field: Field
    let initial: String
    let font: HelixFont
    let alignment: HelixAlignment
    var changed = false
    let onChange: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(HelixFonts.font(font))
            .foregroundStyle(Color.black)
            .multilineTextAlignment(alignment.textAlignment)
            .focused($focused)
            .onAppear { text = initial }
            .onChange(of: text) { onChange(text) }
            .help(field.displayName)
            .background {
                // Unsaved changes are tinted; the field being typed in gets a soft highlight.
                (changed ? Color.orange.opacity(0.12) : focused ? Color.accentColor.opacity(0.07) : Color.clear)
                    .padding(.horizontal, -3).padding(.vertical, -1)
            }
    }
}

enum HelixFonts {
    private static var cache: [HelixFont: NSFont] = [:]

    static func nsFont(_ f: HelixFont) -> NSFont {
        if let hit = cache[f] { return hit }
        let size = CGFloat(max(f.size, 6))
        let fm = NSFontManager.shared
        var font: NSFont?
        if var family = f.family, !["Charcoal", "Chicago"].contains(family) {
            var traits: NSFontTraitMask = []
            for (suffix, trait) in [(" Bold", NSFontTraitMask.boldFontMask), (" Italic", .italicFontMask)] where family.hasSuffix(suffix) {
                family.removeLast(suffix.count)
                traits.insert(trait)
            }
            font = fm.font(withFamily: family, traits: traits, weight: 5, size: size) ?? NSFont(name: f.family!, size: size)
        }
        var result = font ?? .systemFont(ofSize: size)
        if f.bold { result = fm.convert(result, toHaveTrait: .boldFontMask) }
        if f.italic { result = fm.convert(result, toHaveTrait: .italicFontMask) }
        cache[f] = result
        return result
    }

    static func font(_ f: HelixFont) -> Font { Font(nsFont(f) as CTFont) }
}

extension HelixAlignment {
    var frameAlignment: Alignment { [.left: .topLeading, .center: .top, .right: .topTrailing][self]! }
    var textAlignment: TextAlignment { [.left: .leading, .center: .center, .right: .trailing][self]! }
}

/// Draws one template element at its template position (relative to `origin`).
struct TemplateElementView: View {
    let element: TemplateElement
    let context: TemplateContext

    var body: some View {
        let r = element.rect
        content
            .frame(width: CGFloat(max(r.width, 1)), height: CGFloat(max(r.height, 1)), alignment: element.alignment.frameAlignment)
            .clipped()
            .position(x: CGFloat(r.left) + CGFloat(r.width) / 2, y: CGFloat(r.top) + CGFloat(r.height) / 2)
    }

    @ViewBuilder private var content: some View {
        switch element.content {
        case .label(let text):
            styled(Text(text)).padding(.horizontal, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: element.alignment.frameAlignment)
                .overlay { if element.framed { Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1) } }
        case .data:
            ZStack(alignment: element.alignment.frameAlignment) {
                if element.framed || context.record == nil {
                    Rectangle().strokeBorder(Color.black.opacity(context.record == nil ? 0.5 : 0.6), lineWidth: 1)
                }
                if element.scrollsVertically && context.record != nil && !context.forPrint {
                    ScrollView(.vertical) {
                        dataContent.padding(.horizontal, 3).padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: element.alignment.frameAlignment)
                    }
                    .scrollIndicators(.visible)
                } else {
                    dataContent.padding(.horizontal, 3).padding(.vertical, 1)
                }
            }
        case .repeatGroup, .group:
            EmptyView()
        }
    }

    @ViewBuilder private var dataContent: some View {
        if let field = context.editableField(for: element), let editor = context.editor {
            if field.type == .flag {
                Toggle("", isOn: Binding(get: { editor.flag(field) }, set: { editor.setFlag(field, $0) }))
                    .toggleStyle(.checkbox).labelsHidden()
            } else if field.type == .picture {
                PictureWell(image: editor.picture(field), changed: editor.changed(field)) { editor.setPicture(field, $0) }
            } else {
                EditableText(field: field, initial: editor.text(field), font: element.font, alignment: element.alignment,
                             changed: editor.changed(field)) {
                    editor.setText(field, $0)
                }
            }
        } else if let onActivate = context.onActivate, context.record != nil {
            LinkCell { displayContent } action: { onActivate(element) }
        } else {
            displayContent
        }
    }

    @ViewBuilder private var displayContent: some View {
        switch context.value(for: element) {
        case .flag(let on)?:
            Image(systemName: on ? "checkmark.square" : "square").font(HelixFonts.font(element.font))
        case .picture(let data)?:
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help("Picture in a legacy format (\(data.count) bytes)")
            }
        default:
            if let (text, placeholder) = context.text(for: element) {
                if context.onActivate == nil {
                    styled(Text(text).italic(placeholder), color: placeholder ? .gray : .black).textSelection(.enabled)
                } else {
                    styled(Text(text).italic(placeholder), color: placeholder ? .gray : .black)
                }
            }
        }
    }

    private func styled(_ text: Text, color: Color = .black) -> some View {
        text.font(HelixFonts.font(element.font))
            .underline(element.font.underline)
            .foregroundStyle(color)
            .multilineTextAlignment(element.alignment.textAlignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A clickable value in a list: underlined on hover with a pointing-hand cursor.
struct LinkCell<Content: View>: View {
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        content
            .overlay(alignment: .bottomLeading) {
                if hover { Rectangle().fill(Color.accentColor).frame(height: 1).offset(y: -2) }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture(perform: action)
            .help("Click to show records with this value")
    }
}

/// Renders a set of elements on a fixed-size canvas. Groups are flattened.
struct TemplateCanvas: View {
    let elements: [TemplateElement]
    let context: TemplateContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.flatten(elements)) { e in
                TemplateElementView(element: e, context: context)
            }
        }
    }

    static func flatten(_ els: [TemplateElement]) -> [TemplateElement] {
        els.flatMap { e -> [TemplateElement] in
            switch e.content {
            case .group(let c), .repeatGroup(let c): flatten(c)
            default: [e]
            }
        }
    }
}

/// Helix template-editor look: graph paper with rectangles showing icon names.
struct TemplateDesignView: View {
    let template: Template
    let context: TemplateContext

    var body: some View {
        let size = canvasSize
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                GraphPaper().frame(width: size.width, height: size.height)
                if let rep = template.repeatElement {
                    Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                        .frame(width: CGFloat(rep.rect.width), height: CGFloat(rep.rect.height))
                        .offset(x: CGFloat(rep.rect.left), y: CGFloat(rep.rect.top))
                }
                TemplateCanvas(elements: template.elements, context: context)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .padding()
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
        .environment(\.colorScheme, .light)
        .navigationTitle("Template: \(template.name)")
    }

    private var canvasSize: CGSize {
        let b = template.contentBounds
        return CGSize(width: CGFloat(max(b.right, template.page.width) + 10), height: CGFloat(max(b.bottom, 200) + 20))
    }
}

struct GraphPaper: View {
    var spacing: CGFloat = 8
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for x in stride(from: 0, through: size.width, by: spacing) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: 0, through: size.height, by: spacing) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
            ctx.stroke(p, with: .color(Color.blue.opacity(0.08)), lineWidth: 0.5)
        }
    }
}
