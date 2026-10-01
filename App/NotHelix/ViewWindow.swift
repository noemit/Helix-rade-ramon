import HelixKit
import SwiftUI

/// Identifies a view to show in its own window (as Helix opened each view in a window).
struct ViewWindowRef: Codable, Hashable {
    let modelID: UUID
    let viewID: Int
}

/// Open collections, so separate view windows can find their collection.
@MainActor
enum ModelRegistry {
    private final class Weak { weak var model: CollectionModel?; init(_ m: CollectionModel) { model = m } }
    private static var models: [UUID: Weak] = [:]

    static func register(_ m: CollectionModel) { models[m.id] = Weak(m) }
    static func model(_ id: UUID) -> CollectionModel? { models[id]?.model }
}

struct ViewWindow: View {
    let ref: ViewWindowRef

    var body: some View {
        if let model = ModelRegistry.model(ref.modelID) {
            ViewWindowContent(model: model, viewID: ref.viewID)
        } else {
            ContentUnavailableView("Collection Closed", systemImage: "xmark.rectangle",
                                   description: Text("Open the collection again to see this view."))
        }
    }
}

private struct ViewWindowContent: View {
    @ObservedObject var model: CollectionModel
    let viewID: Int

    var body: some View {
        let _ = model.revision
        if let view = model.design.view(id: viewID), let rel = model.relation(ofView: view), let t = model.template(for: view),
           let ev = model.evaluator(for: view) {
            HelixViewPane(view: view, template: t, design: model.design, relation: rel, records: ev.records, evaluator: ev,
                          actions: model.actions(for: view), sort: model.sortControl(for: view),
                          navigation: model.navigation(for: view), currentIndex: model.recordIndexBinding(for: view))
                .navigationTitle("\(view.name) — \(model.design.name)")
                .frame(minWidth: 500, minHeight: 360)
                .focusedSceneObject(model)
        } else {
            ContentUnavailableView("View Not Found", systemImage: "macwindow")
        }
    }
}
