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

/// Information about a design object, plus its original Helix bytes when it came from the file.
struct DesignObjectView: View {
    let design: Design
    let objectID: Int

    private var helixObject: DesignObject? { design.collection?.objects[objectID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(design.name(of: objectID).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(objectID)").font(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Kind", design.kind(of: objectID)?.displayName ?? helixObject?.kind?.displayName ?? "Unknown")
                    row("Object ID", "\(objectID)")
                    row("Origin", helixObject == nil ? "Created in Faulix" : "Helix file")
                }
                if let o = helixObject, let heap = design.collection?.heap {
                    DisclosureGroup("Original Helix bytes (\(o.length) bytes at block \(o.block))") {
                        Text(Self.hexDump(heap, o))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    static func hexDump(_ heap: HeapFile, _ object: DesignObject) -> String {
        let bytes = Array(heap.slice(Int(object.block) * 32, min(object.length, 4096)))
        return stride(from: 0, to: bytes.count, by: 16).map { i in
            let chunk = bytes[i..<min(i + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%04x  ", i) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
}
