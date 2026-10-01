import SwiftUI

/// Quickstart guides, one per page. Shown from the "?" button in each page's toolbar and
/// all together from Help ▸ Faulix Quickstart.
enum HelpTopic: String, CaseIterable, Identifiable {
    case welcome, form, list, history, export, collection, relation, records, field, template, abacus, query, view, index, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome to Faulix"
        case .form: "Forms (User mode)"
        case .list: "Lists (User mode)"
        case .history: "History and Undo"
        case .export: "Exporting"
        case .collection: "Collection window (Design mode)"
        case .relation: "Relation window (Design mode)"
        case .records: "Browse Records"
        case .field: "Fields"
        case .template: "Template editor"
        case .abacus: "Abacus (formula) editor"
        case .query: "Queries"
        case .view: "Views"
        case .index: "Indexes (sort orders)"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .form: "doc.text"
        case .list: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .export: "square.and.arrow.up"
        case .collection: "square.grid.2x2"
        case .relation: "archivebox"
        case .records: "tablecells"
        case .field: "character.textbox"
        case .template: "rectangle.3.group"
        case .abacus: "function"
        case .query: "questionmark.square.dashed"
        case .view: "macwindow"
        case .index: "list.number"
        case .settings: "gearshape"
        }
    }

    var intro: String {
        switch self {
        case .welcome:
            "Faulix opens Helix collections and works the way Helix does: User mode to look up and enter data, Design mode to change the collection. Your original Helix file is never changed — Faulix keeps its own copy."
        case .form:
            "A form shows one record at a time, laid out exactly like your Helix template. Type straight into any field."
        case .list:
            "A list shows many records, one row each, using the template’s repeat rectangle. Every field in a row can be edited in place."
        case .history:
            "Every change — records and design — is logged. You can undo step by step, or put an old version of a record back."
        case .export:
            "Take your data out of Faulix: back into Helix, into a spreadsheet, or as a database file."
        case .collection:
            "The top window of the collection, like Helix RADE: one icon per relation (table) and user."
        case .relation:
            "Everything that belongs to one relation, as icons: fields, abaci, templates, views, queries and indexes. Arrange them however you like."
        case .records:
            "A plain spreadsheet of every record in the relation — handy for checking data. Use views in User mode for everyday work."
        case .field:
            "A field holds one piece of data in every record: text, a number, a date, a yes/no flag or a picture."
        case .template:
            "A template is the layout of a form or list: labels, data rectangles (fields and abaci) and, for lists, a repeat rectangle."
        case .abacus:
            "An abacus calculates a value from fields and other abaci — like a spreadsheet formula. Helix built them from tiles; in Faulix you type them."
        case .query:
            "A query picks which records a view shows. It is a formula that is true for the records you want."
        case .view:
            "A view is what you open in User mode: a template, plus an optional query and sort order."
        case .index:
            "An index is a sort order: records are ordered by its first key, then the second, and so on."
        case .settings:
            "Faulix ▸ Settings… holds options that apply to every collection."
        }
    }

    var steps: [String] {
        switch self {
        case .welcome: [
            "Choose File ▸ Open… and pick your Helix collection.",
            "User mode (top left): pick a form or list in the sidebar to work with your data.",
            "Design mode: double-click icons to change fields, layouts, formulas, views, queries and indexes.",
            "Press the ? button on any page for help with that page.",
        ]
        case .form: [
            "Click a field and type. Changed fields turn orange.",
            "Replace (⌘S) saves your changes; Revert (Esc) throws them away.",
            "New (⇧⌘N) starts a blank record with Helix’s default values; press Enter (⌘S) to save it.",
            "Move between records with the arrows or ⌘↑ / ⌘↓ (⌥⌘↑ / ⌥⌘↓ for first and last).",
            "Change the sort order from the ⇅ menu at the bottom right.",
            "Find (top right) narrows the records to those containing your words.",
        ]
        case .list: [
            "Click a row to select it; type into any field to edit it. Changed rows get an orange bar.",
            "Replace (⌘S) saves every changed row at once; Revert (Esc) discards them.",
            "New (⇧⌘N) adds a blank row at the top. Delete removes the selected row (after asking).",
            "Totals and counts in the header follow the records shown (query and Find).",
            "Change the sort order from the ⇅ menu at the bottom right.",
        ]
        case .history: [
            "Edit ▸ Undo (⌘Z) and Redo (⇧⌘Z) step through your changes, including design changes.",
            "While typing in a field, ⌘Z undoes your typing instead.",
            "The clock button opens the History: newest first. Click a record change to see old → new values.",
            "Restore Previous Version puts that record back as it was before the change (and is logged too).",
        ]
        case .export: [
            "Export ▸ Export Records… writes the current view as Helix import text or CSV.",
            "For Helix: import the file into the same view — columns follow its tab order.",
            "Export Collection as JSON… writes every relation and record.",
            "Save a Copy of the Database… gives you a SQLite file any database tool can open.",
        ]
        case .collection: [
            "Double-click a relation to open its window.",
            "New ▸ Relation… adds an empty relation (table).",
            "Drag icons to arrange them. Right-click an icon to rename or delete it.",
            "Switch between Icon and List display at the top right.",
        ]
        case .relation: [
            "Double-click an icon to open its editor.",
            "New (toolbar) adds a field, abacus, template, view, query or index.",
            "Right-click an icon: Open, Rename, Duplicate or Delete. Delete warns you if other things use it.",
            "Drag icons to arrange them; positions are saved.",
            "Browse Records shows all records of the relation in a table.",
        ]
        case .records: [
            "Click a column header to sort; use Search to filter.",
            "Select a record to see every field on the right.",
        ]
        case .field: [
            "Change the name or the type and it is saved at once (undo with ⌘Z).",
            "To show a new field on a form, open a template and use Add ▸ Field.",
            "“Used by” lists the templates, abaci and indexes that refer to this field.",
            "Changing the type does not convert existing values; check them in Browse Records.",
        ]
        case .template: [
            "Click a rectangle to select it; drag to move, drag the corner handle to resize. Arrow keys nudge (⇧ for 10).",
            "Add ▸ Label, Field or Abacus places a new rectangle; Delete (⌫) removes the selection.",
            "The inspector on the right edits text, the field or abacus shown, font, size, style, alignment, frame and scroll bar.",
            "For lists, rectangles inside the dashed repeat rectangle repeat once per record. Make List adds one.",
            "Changes are saved as you go; ⌘Z undoes them.",
        ]
        case .abacus: [
            "Type the formula; Faulix checks it as you type and shows the result for the first records.",
            "[Field name] uses a field, {Abacus name} another abacus, \"text\" a text, numbers as 166.386.",
            "Operators: & joins text; + − × ÷; = ≠ < ≤ > ≥; contains; starts with.",
            "if … then … else … chooses; functions: text() number() date() day() month() year() defined() undefined() default(a, b) total() maximum() previous(), and today, return, count.",
            "Use the Insert menus to add fields, abaci, functions and operators. Apply (⌘S) saves.",
        ]
        case .query: [
            "Write a formula that is true for the records you want, e.g. [Clasificación] contains \"Poesía\".",
            "The preview shows how many records match.",
            "Choose the query in a view’s settings to make that view show only those records.",
        ]
        case .view: [
            "Pick the template that lays out the records.",
            "Optionally pick a query (which records) and a sort order (index).",
            "The preview below shows the view; Open in User Mode jumps there.",
            "New views appear in the User mode sidebar under Forms or Lists.",
        ]
        case .index: [
            "Add keys with Add Key; the first key sorts first, the next breaks ties, and so on.",
            "Reorder keys with the arrows; remove with the minus button.",
            "Views use an index as their sort order; users can also pick it from the ⇅ menu.",
        ]
        case .settings: [
            "Numbers: choose the region for decimal and thousands separators, and the currency symbol.",
        ]
        }
    }
}

struct HelpContent: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(topic.title, systemImage: topic.symbol).font(.headline)
            Text(topic.intro).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.callout)
    }
}

/// The "?" toolbar button that shows a page's quickstart.
struct HelpButton: View {
    let topic: HelpTopic
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Label("Help", systemImage: "questionmark.circle") }
            .help("Quickstart: \(topic.title)")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ScrollView {
                    HelpContent(topic: topic).padding(16)
                }
                .frame(width: 380)
                .frame(maxHeight: 460)
            }
    }
}

/// Help ▸ Faulix Quickstart: every guide in one window.
struct QuickstartWindow: View {
    @State private var topic: HelpTopic? = .welcome

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $topic) { t in
                Label(t.title, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(220)
        } detail: {
            ScrollView {
                HelpContent(topic: topic ?? .welcome)
                    .padding(24)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }
}
