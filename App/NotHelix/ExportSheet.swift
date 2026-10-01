import AppKit
import HelixKit
import SwiftUI
import UniformTypeIdentifiers

/// Export records for re-import into Helix (tab-delimited) or for other tools (CSV).
struct ExportSheet: View {
    @ObservedObject var model: CollectionModel
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case helix = "Helix import text", csv = "CSV"
        var id: String { rawValue }
    }
    enum Scope: String, CaseIterable, Identifiable {
        case view = "Records in the current view", all = "All records of the relation"
        var id: String { rawValue }
    }
    enum FieldSet: String, CaseIterable, Identifiable {
        case layout = "Fields on the view, in tab order", all = "All fields"
        var id: String { rawValue }
    }
    enum RecordEnd: String, CaseIterable, Identifiable {
        case cr = "Return", rs = "Record separator (ASCII 30)"
        var id: String { rawValue }
    }

    @State private var format: Format = .helix
    @State private var scope: Scope = .view
    @State private var fieldSet: FieldSet = .layout
    @State private var newlines: Exporter.HelixTextOptions.Newlines = .verticalTab
    @State private var recordEnd: RecordEnd = .cr
    @State private var macRoman = false
    @State private var header = false

    var body: some View {
        let view = model.exportView
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Export Records").font(.title2.bold())
                Spacer()
                HelpButton(topic: .export).labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if let view, let rel = model.relation(ofView: view) {
                Text("From the view “\(view.name)” of \(rel.name).").foregroundStyle(.secondary)
            }
            Form {
                Picker("Format", selection: $format) { ForEach(Format.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Records", selection: $scope) { ForEach(Scope.allCases) { Text(label($0)).tag($0) } }
                Picker("Fields", selection: $fieldSet) { ForEach(FieldSet.allCases) { Text($0.rawValue).tag($0) } }
                if format == .helix {
                    Picker("Returns inside text", selection: $newlines) {
                        ForEach(Exporter.HelixTextOptions.Newlines.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Record delimiter", selection: $recordEnd) { ForEach(RecordEnd.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Mac Roman text encoding (for older Helix versions)", isOn: $macRoman)
                    Toggle("First line lists field names", isOn: $header)
                }
            }
            .formStyle(.grouped)
            if format == .helix {
                Label {
                    Text("In Helix, import this file into the same view: columns follow the view’s tab order. If text contains returns, keep “Vertical tab” (or pick the ASCII 30 record delimiter and set the same in the view’s import settings).")
                } icon: { Image(systemName: "info.circle") }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.keyboardShortcut(.defaultAction).disabled(view == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func label(_ s: Scope) -> String {
        guard let v = model.exportView, let rel = model.relation(ofView: v) else { return s.rawValue }
        let n = s == .view ? model.records(for: v).count : model.baseRecords(rel).records.count
        return "\(s.rawValue) (\(n))"
    }

    private func export() {
        guard let view = model.exportView, let rel = model.relation(ofView: view) else { return }
        let records = scope == .view ? model.records(for: view) : model.baseRecords(rel).records
        let fields: [Field] = fieldSet == .all ? rel.fields
            : (model.template(for: view)?.fieldOrder.compactMap(rel.field(objectID:)) ?? rel.fields)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .plainText]
        panel.nameFieldStringValue = "\(view.name).\(format == .csv ? "csv" : "txt")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if format == .csv {
                try Exporter.csv(fields: fields, records: records).write(to: url, atomically: true, encoding: .utf8)
            } else {
                var o = Exporter.HelixTextOptions()
                o.newlines = newlines
                o.recordDelimiter = recordEnd == .cr ? "\r" : "\u{1E}"
                o.includeHeader = header
                let text = Exporter.helixText(fields: fields, records: records, options: o)
                guard let data = text.data(using: macRoman ? .macOSRoman : .utf8, allowLossyConversion: macRoman) else {
                    throw HelixFormatError("Could not encode the text.")
                }
                try data.write(to: url)
            }
            dismiss()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
