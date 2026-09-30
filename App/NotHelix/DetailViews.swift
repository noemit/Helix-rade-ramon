import HelixKit
import SwiftUI

struct RecordDetailView: View {
    let relation: Relation
    let record: Record
    @AppStorage("showEmptyFields") private var showEmpty = false

    var body: some View {
        ScrollView {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(relation.fields.filter { showEmpty || record[$0] != nil }) { field in
                    GridRow {
                        Text(field.displayName)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                            .frame(minWidth: 110, alignment: .trailing)
                        valueView(record[field])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showEmpty) { Label("Show Empty Fields", systemImage: "eye") }
                    .help("Show fields that have no value in this record")
            }
        }
        .navigationTitle("Record \(record.id)")
    }

    @ViewBuilder private func valueView(_ value: Value?) -> some View {
        switch value {
        case .picture(let data)?:
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
            } else {
                Text(value!.description).foregroundStyle(.secondary)
            }
        case .flag(let b)?:
            Image(systemName: b ? "checkmark.square" : "square")
        case let v?:
            Text(v.description).textSelection(.enabled)
        case nil:
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// Design-mode inspector: shows what is known about an object plus its raw bytes.
struct DesignObjectView: View {
    let collection: HelixCollection
    let object: DesignObject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(object.name.isEmpty ? "#\(object.id)" : object.name).font(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Kind", object.kind?.displayName ?? "Unknown (\(object.rawKind))")
                    row("Object ID", "\(object.id)")
                    row("Heap block", "\(object.block) (offset 0x\(String(object.block * 32, radix: 16)))")
                    row("Size", "\(object.length) bytes")
                    if let field = collection.relations.lazy.flatMap(\.fields).first(where: { $0.id == object.id }) {
                        row("Field number", "\(field.fieldID)")
                        row("Type", field.type.description)
                        if let c = field.created { row("Created", c.description) }
                        if let m = field.modified { row("Modified", m.description) }
                    }
                }
                if let a = collection.abacus(id: object.id) ?? collection.queryAbacusID(ofQuery: object.id).flatMap(collection.abacus(id:)) {
                    GroupBox("Formula") {
                        Text(collection.formulaText(a.root).isEmpty ? "(empty)" : collection.formulaText(a.root))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GroupBox("Raw bytes") {
                    Text(hexDump)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var hexDump: String {
        let bytes = Array(collection.heap.slice(Int(object.block) * 32, min(object.length, 4096)))
        return stride(from: 0, to: bytes.count, by: 16).map { i in
            let chunk = bytes[i..<min(i + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%04x  ", i) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
}
