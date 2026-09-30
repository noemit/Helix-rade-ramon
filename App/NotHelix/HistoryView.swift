import AppKit
import HelixKit
import SwiftUI

/// The change log: every Enter, Replace, Delete, Undo and Restore, newest first.
struct HistoryView: View {
    @ObservedObject var model: CollectionModel
    @State private var selection: Int?

    var body: some View {
        let entries = model.history()
        let _ = model.revision
        VStack(spacing: 0) {
            HStack {
                Button { model.undoManager.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.undoManager.canUndo)
                    .help(model.undoManager.undoMenuItemTitle)
                Button { model.undoManager.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!model.undoManager.canRedo)
                    .help(model.undoManager.redoMenuItemTitle)
                Spacer()
                Text("\(entries.count) changes").font(.caption).foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No Changes Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Every record you enter, replace or delete is logged here and can be restored."))
            } else {
                List(entries, selection: $selection) { e in
                    HistoryRow(model: model, entry: e, expanded: selection == e.id)
                        .tag(e.id)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 280)
    }
}

struct HistoryRow: View {
    @ObservedObject var model: CollectionModel
    let entry: RecordStore.HistoryEntry
    let expanded: Bool

    private var relation: Relation? { model.collection.relations.first { $0.id == entry.relationID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let rel = relation {
                Text(model.label(for: entry.after ?? entry.before, in: rel).nilIfEmpty ?? "Record \(entry.recordID)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption2).foregroundStyle(.tertiary)
                }
                if expanded {
                    ForEach(entry.changedFields, id: \.self) { fid in
                        let name = rel.field(withID: fid)?.displayName ?? "Field \(fid)"
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.caption2.weight(.semibold))
                            Text(short(entry.before?.values[fid])).strikethrough().foregroundStyle(.red.opacity(0.8))
                            Text(short(entry.after?.values[fid])).foregroundStyle(.green)
                        }
                        .font(.caption)
                        .padding(.leading, 22)
                    }
                    Button("Restore Previous Version") { model.restore(before: entry) }
                        .controlSize(.small)
                        .padding(.leading, 22)
                        .help("Put this record back the way it was before this change. The restore is logged too.")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        let rel = relation?.name ?? "Record"
        switch entry.action {
        case .insert: return "New \(rel) record"
        case .update: return "Changed \(entry.changedFields.count) field\(entry.changedFields.count == 1 ? "" : "s")"
        case .delete: return "Deleted \(rel) record"
        }
    }

    private var symbol: String {
        switch entry.action {
        case .insert: "plus.circle.fill"
        case .update: "pencil.circle.fill"
        case .delete: "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch entry.action {
        case .insert: .green
        case .update: .blue
        case .delete: .red
        }
    }

    private func short(_ v: Value?) -> String {
        guard let v else { return "(empty)" }
        let s = v.description.replacingOccurrences(of: "\n", with: " ⏎ ")
        return s.count > 120 ? String(s.prefix(120)) + "…" : s
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Edit ▸ Undo/Redo for record changes. While a text field is being edited, the
/// commands go to the text field instead, so typing can still be undone normally.
struct UndoCommands: View {
    @FocusedObject var model: CollectionModel?

    var body: some View {
        let um = model?.undoManager
        let _ = model?.revision
        Button(um?.canUndo == true ? um!.undoMenuItemTitle : "Undo") { perform(#selector(UndoManager.undo), "undo:") }
            .keyboardShortcut("z", modifiers: .command)
        Button(um?.canRedo == true ? um!.redoMenuItemTitle : "Redo") { perform(#selector(UndoManager.redo), "redo:") }
            .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    private func perform(_ selector: Selector, _ textAction: String) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(Selector((textAction)), to: nil, from: nil)
        } else if let um = model?.undoManager {
            _ = um.perform(selector)
        }
    }
}
