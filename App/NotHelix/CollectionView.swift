import HelixKit
import SwiftUI

struct CollectionView: View {
    @StateObject var model: CollectionModel

    var body: some View {
        Group {
            switch model.mode {
            case .user: userMode
            case .design: designMode
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("User mode shows views as Helix forms; Design mode shows the collection's structure")
            }
            ToolbarItem {
                Menu {
                    Button("Update from Newer Helix File…", action: model.updateFromHelix)
                    Divider()
                    Button("Export Records…") { model.showExport = true }
                        .disabled(model.exportView == nil)
                    Button("Export View as PDF…", action: model.exportPDF)
                        .disabled(model.exportView == nil)
                    Button("Export Collection as JSON…", action: model.exportJSON)
                    Divider()
                    Button("Save a Copy of the Database…", action: model.saveDatabaseCopy)
                    Button("Show Database in Finder", action: model.revealDatabase)
                    Divider()
                    Button("Back Up Now", action: model.backUpNow)
                    Button("Show Backups in Finder", action: model.showBackups)
                } label: {
                    Label("Data", systemImage: "square.and.arrow.up.on.square")
                }
                .help("Update from Helix, export, backups")
            }
            ToolbarItem {
                Button { model.printView(allRecords: false) } label: { Label("Print", systemImage: "printer") }
                    .disabled(model.exportView == nil)
                    .help(model.printIsForm ? "Print this record (⌘P) — File ▸ Print All Records for every record" : "Print the list (⌘P)")
            }
            ToolbarItem {
                Toggle(isOn: $model.showHistory) { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("Show the log of every change, with undo and restore")
            }
        }
        .inspector(isPresented: $model.showHistory) {
            HistoryView(model: model).inspectorColumnWidth(min: 280, ideal: 320, max: 460)
        }
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .focusedSceneObject(model)
    }

    private var userMode: some View {
        NavigationSplitView {
            ViewSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let view = model.openView, let rel = model.relation(ofView: view), let template = model.template(for: view),
               let evaluator = model.evaluator(for: view) {
                HelixViewPane(view: view, template: template, design: model.design, relation: rel,
                              records: evaluator.records, evaluator: evaluator, actions: model.actions(for: view),
                              sort: model.sortControl(for: view), navigation: model.navigation(for: view),
                              currentIndex: model.recordIndexBinding(for: view))
                    .id(view.id)
                    .navigationSubtitle(viewSubtitle(view, rel))
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button(action: model.goBack) { Label("Back", systemImage: "chevron.left") }
                                .disabled(model.backStack.isEmpty)
                                .keyboardShortcut("[", modifiers: .command)
                                .help(model.backStack.last.flatMap { model.design.name(of: $0.viewID) }.map { "Back to \($0) (⌘[)" } ?? "Back")
                        }
                        ToolbarItem { HelpButton(topic: template.repeatElement == nil ? .form : .list) }
                    }
            } else {
                ContentUnavailableView("No View Open", systemImage: "macwindow",
                                       description: Text("Choose a view from the list, or create one in Design mode."))
                    .toolbar { ToolbarItem { HelpButton(topic: .welcome) } }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Find")
        .navigationTitle(model.design.name)
    }

    private func viewSubtitle(_ view: ViewDefinition, _ rel: Relation) -> String {
        var parts = ["\(model.records(for: view).count) records"]
        if let d = model.drills[view.id] { parts.append(d.title) }
        if let q = view.queryID, let name = model.design.name(of: q) { parts.append("query “\(name)”") }
        if let i = view.indexID ?? view.defaultIndexID, let name = model.design.name(of: i) { parts.append("sorted by \(name)") }
        return parts.joined(separator: " · ")
    }

    private var designMode: some View { DesignModeView(model: model) }
}

struct RecordsPane: View {
    @ObservedObject var model: CollectionModel

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView("Could Not Read Records", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let rel = model.relation {
                if rel.fields.isEmpty || model.totalRecordCount == 0 {
                    ContentUnavailableView("No Records", systemImage: "tablecells",
                                           description: Text("“\(rel.name)” has no records."))
                } else {
                    RecordTable(fields: rel.fields, records: model.records, selection: $model.selectedRecordID)
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search records")
        .onChange(of: model.searchText) { model.applySearch() }
    }
}

/// User-mode sidebar: each relation's views, split into forms and lists.
struct ViewSidebar: View {
    @ObservedObject var model: CollectionModel

    private struct Group: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let views: [ViewDefinition]
    }

    private var groups: [Group] {
        let multi = model.viewsByRelation.count > 1
        return model.viewsByRelation.flatMap { rel, views -> [Group] in
            let forms = views.filter { model.template(for: $0)?.repeatElement == nil }
            let lists = views.filter { model.template(for: $0)?.repeatElement != nil }
            return [
                Group(id: "\(rel.id)-f", title: multi ? "\(rel.name) · Forms" : "Forms", symbol: "doc.text", views: forms),
                Group(id: "\(rel.id)-l", title: multi ? "\(rel.name) · Lists" : "Lists", symbol: "list.bullet.rectangle", views: lists),
            ].filter { !$0.views.isEmpty }
        }
    }

    var body: some View {
        let _ = model.revision
        List(selection: $model.openViewID) {
            ForEach(groups) { g in
                Section(g.title) {
                    ForEach(g.views) { v in
                        Label(v.name, systemImage: g.symbol)
                            .help(model.iconSummary(v.id))
                            .tag(v.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
