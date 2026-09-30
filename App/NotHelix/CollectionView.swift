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
                    Button("Export Records…") { model.showExport = true }
                        .disabled(model.exportView == nil)
                    Button("Export Collection as JSON…", action: model.exportJSON)
                    Divider()
                    Button("Save a Copy of the Database…", action: model.saveDatabaseCopy)
                    Button("Show Database in Finder", action: model.revealDatabase)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export records for Helix or other apps")
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
            List(selection: $model.openViewID) {
                ForEach(model.viewsByRelation, id: \.0.id) { rel, views in
                    let forms = views.filter { model.template(for: $0)?.repeatElement == nil }
                    let lists = views.filter { model.template(for: $0)?.repeatElement != nil }
                    ForEach([("Forms", forms, "doc.text"), ("Lists", lists, "list.bullet.rectangle")], id: \.0) { title, vs, symbol in
                        if !vs.isEmpty {
                            Section(model.viewsByRelation.count > 1 ? "\(rel.name) · \(title)" : title) {
                                ForEach(vs) { v in
                                    Label(v.name, systemImage: symbol)
                                        .help(model.iconSummary(model.collection.objects[v.id]!))
                                        .tag(v.id)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let view = model.openView, let rel = model.relation(ofView: view), let template = model.template(for: view),
               let evaluator = model.evaluator(for: view) {
                HelixViewPane(view: view, template: template, collection: model.collection, relation: rel,
                              records: evaluator.records, evaluator: evaluator, actions: model.actions(for: view),
                              sort: model.sortControl(for: view), currentIndex: model.recordIndexBinding(for: view))
                    .id(view.id)
                    .navigationSubtitle(viewSubtitle(view, rel))
            } else {
                ContentUnavailableView("No View Open", systemImage: "macwindow",
                                       description: Text("Choose a view from the list."))
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Find")
        .navigationTitle(model.collection.name)
    }

    private func viewSubtitle(_ view: ViewDefinition, _ rel: Relation) -> String {
        var parts = ["\(model.records(for: view).count) records"]
        if let q = view.queryID, let name = model.collection.objects[q]?.name { parts.append("query “\(name)”") }
        if let i = view.indexID ?? view.defaultIndexID, let name = model.collection.objects[i]?.name { parts.append("sorted by \(name)") }
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
