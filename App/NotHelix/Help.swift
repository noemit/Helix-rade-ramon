import SwiftUI

/// Quickstart guides, one per page. Shown from the "?" button in each page's toolbar and
/// all together from Help ▸ Faulix Quickstart.
enum HelpTopic: String, CaseIterable, Identifiable {
    case welcome, form, list, history, export, collection, relation, records, field, template, abacus, query, view, index, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: L("Welcome to Faulix")
        case .form: L("Forms (User mode)")
        case .list: L("Lists (User mode)")
        case .history: L("History and Undo")
        case .export: L("Printing, exporting and backups")
        case .collection: L("Collection window (Design mode)")
        case .relation: L("Relation window (Design mode)")
        case .records: L("Browse Records")
        case .field: L("Fields")
        case .template: L("Template editor")
        case .abacus: L("Abacus (formula) editor")
        case .query: L("Queries")
        case .view: L("Views")
        case .index: L("Indexes (sort orders)")
        case .settings: L("Settings")
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
            L("Faulix opens Helix collections and works the way Helix does: User mode to look up and enter data, Design mode to change the collection. Your original Helix file is never changed — Faulix keeps its own copy.")
        case .form:
            L("A form shows one record at a time, laid out exactly like your Helix template. Type straight into any field.")
        case .list:
            L("A list shows many records, one row each, using the template’s repeat rectangle. Every field in a row can be edited in place.")
        case .history:
            L("Every change — records and design — is logged. You can undo step by step, or put an old version of a record back.")
        case .export:
            L("Print your views, bring in a newer Helix file, take your data out of Faulix, and keep backups.")
        case .collection:
            L("The top window of the collection, like Helix RADE: one icon per relation (table) and user.")
        case .relation:
            L("Everything that belongs to one relation, as icons: fields, abaci, templates, views, queries and indexes. Arrange them however you like.")
        case .records:
            L("A plain spreadsheet of every record in the relation — handy for checking data. Use views in User mode for everyday work.")
        case .field:
            L("A field holds one piece of data in every record: text, a number, a date, a yes/no flag or a picture.")
        case .template:
            L("A template is the layout of a form or list: labels, data rectangles (fields and abaci) and, for lists, a repeat rectangle.")
        case .abacus:
            L("An abacus calculates a value from fields and other abaci — like a spreadsheet formula. Helix built them from tiles; in Faulix you type them.")
        case .query:
            L("A query picks which records a view shows. It is a formula that is true for the records you want.")
        case .view:
            L("A view is what you open in User mode: a template, plus an optional query and sort order.")
        case .index:
            L("An index is a sort order: records are ordered by its first key, then the second, and so on.")
        case .settings:
            L("Faulix ▸ Settings… holds options that apply to every collection.")
        }
    }

    var steps: [String] {
        switch self {
        case .welcome: [
            L("Choose File ▸ Open… and pick your Helix collection."),
            L("User mode (top left): pick a form or list in the sidebar to work with your data."),
            L("Design mode: double-click icons to change fields, layouts, formulas, views, queries and indexes."),
            L("Right-click a view in the sidebar ▸ Open in New Window to keep several views open side by side."),
            L("Press the ? button on any page for help with that page."),
        ]
        case .form: [
            L("Click a field and type. Changed fields turn orange."),
            L("Replace (⌘S) saves your changes; Revert (Esc) throws them away."),
            L("New (⇧⌘N) starts a blank record with Helix’s default values; press Enter (⌘S) to save it."),
            L("Move between records with the arrows or ⌘↑ / ⌘↓ (⌥⌘↑ / ⌥⌘↓ for first and last)."),
            L("Change the sort order from the ⇅ menu at the bottom right."),
            L("Find (top right) narrows the records to those containing your words — accents, commas and word order don’t matter."),
            L("Opened from a list? Back (⌘[) returns to it."),
            L("Find (⇧⌘F) blanks the form so you can type what to look for in any fields — e.g. a town in one field and > 1990 in a year field — then press Find. Use = for exact, ≠ for “not”, < > ≤ ≥ for ranges; = alone finds empty fields. Clear with the × on the chip."),
        ]
        case .list: [
            L("Click any value to see only the records that share it — e.g. click an author to list all their books. Clear the filter with the × on its chip."),
            L("Clicking a value only one record has (usually a title), double-clicking a row, or its › button opens that record on a form. Back (⌘[) returns."),
            L("Find (top right) ignores accents, commas and word order: “Smith, John” also finds “John Smith”."),
            L("Press Edit to type into rows. Changed rows get an orange bar."),
            L("Replace (⌘S) saves every changed row at once; Revert (Esc) discards them."),
            L("New (⇧⌘N) adds a blank row at the top. Delete removes the selected row (after asking)."),
            L("Totals and counts in the header follow the records shown (query and Find)."),
            L("Change the sort order from the ⇅ menu at the bottom right."),
        ]
        case .history: [
            L("Edit ▸ Undo (⌘Z) and Redo (⇧⌘Z) step through your changes, including design changes."),
            L("While typing in a field, ⌘Z undoes your typing instead."),
            L("The clock button opens the History: newest first. Click a record change to see old → new values."),
            L("Restore Previous Version puts that record back as it was before the change (and is logged too)."),
        ]
        case .export: [
            L("Data ▸ Update from Newer Helix File… brings in records added or changed in Helix since. Records you changed in Faulix are kept; a backup is made first."),
            L("Faulix backs up its database every day (Data ▸ Show Backups in Finder); Back Up Now makes one immediately."),
            L("File ▸ Print (⌘P) prints the open view: forms one record per page (Print All Records for every record), lists with the header on every page. Export View as PDF saves the same pages."),
            L("Data ▸ Export Records… writes the current view as Helix import text or CSV."),
            L("For Helix: import the file into the same view — columns follow its tab order."),
            L("Export Collection as JSON… writes every relation and record."),
            L("Save a Copy of the Database… gives you a SQLite file any database tool can open."),
        ]
        case .collection: [
            L("Double-click a relation to open its window."),
            L("New ▸ Relation… adds an empty relation (table)."),
            L("Drag icons to arrange them. Right-click an icon to rename or delete it."),
            L("Switch between Icon and List display at the top right."),
        ]
        case .relation: [
            L("Double-click an icon to open its editor."),
            L("New (toolbar) adds a field, abacus, template, view, query or index."),
            L("Right-click an icon: Open, Rename, Duplicate or Delete. Delete warns you if other things use it."),
            L("Drag icons to arrange them; positions are saved."),
            L("Browse Records shows all records of the relation in a table."),
        ]
        case .records: [
            L("Click a column header to sort; use Search to filter."),
            L("Select a record to see every field on the right."),
        ]
        case .field: [
            L("Change the name or the type and it is saved at once (undo with ⌘Z)."),
            L("To show a new field on a form, open a template and use Add ▸ Field."),
            L("“Used by” lists the templates, abaci and indexes that refer to this field."),
            L("Changing the type does not convert existing values; check them in Browse Records."),
        ]
        case .template: [
            L("Click a rectangle to select it; drag to move, drag the corner handle to resize. Arrow keys nudge (⇧ for 10)."),
            L("Add ▸ Label, Field or Abacus places a new rectangle; Delete (⌫) removes the selection."),
            L("The inspector on the right edits text, the field or abacus shown, font, size, style, alignment, frame and scroll bar."),
            L("For lists, rectangles inside the dashed repeat rectangle repeat once per record. Make List adds one."),
            L("Changes are saved as you go; ⌘Z undoes them."),
        ]
        case .abacus: [
            L("Type the formula; Faulix checks it as you type and shows the result for the first records."),
            L("[Field name] uses a field, {Abacus name} another abacus, \"text\" a text, numbers as 166.386."),
            L("Operators: & joins text; + − × ÷; = ≠ < ≤ > ≥; contains, starts with, ends with; and, or, not()."),
            L("if … then … else … chooses. Text: text() length() upper() lower() trim() left(t, n) right(t, n) mid(t, start, n). Numbers: number() round(x, decimals) abs() int() min(a, b) max(a, b)."),
            L("Dates: date() day() month() year() weekday() makedate(d, m, y), today. Others: defined() undefined() default(a, b) previous(); totals over the records shown: total() average() minimum() maximum() count."),
            L("Use the Insert menus to add fields, abaci, functions and operators. Apply (⌘S) saves."),
        ]
        case .query: [
            L("Write a formula that is true for the records you want, e.g. [Genre] contains \"Poetry\"."),
            L("The preview shows how many records match."),
            L("Choose the query in a view’s settings to make that view show only those records."),
        ]
        case .view: [
            L("Pick the template that lays out the records."),
            L("Optionally pick a query (which records) and a sort order (index)."),
            L("The preview below shows the view; Open in User Mode jumps there."),
            L("New views appear in the User mode sidebar under Forms or Lists."),
        ]
        case .index: [
            L("Add keys with Add Key; the first key sorts first, the next breaks ties, and so on."),
            L("Reorder keys with the arrows; remove with the minus button."),
            L("Views use an index as their sort order; users can also pick it from the ⇅ menu."),
        ]
        case .settings: [
            L("Numbers: choose the region for decimal and thousands separators, and the currency symbol."),
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
            .help(L("Quickstart: \(topic.title)"))
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
