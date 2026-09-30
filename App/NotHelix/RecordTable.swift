import AppKit
import HelixKit
import SwiftUI

/// Sortable, dynamic-column record list backed by NSTableView.
struct RecordTable: NSViewRepresentable {
    let fields: [Field]
    let records: [Record]
    @Binding var selection: Record.ID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowSizeStyle = .default
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: RecordTable
        weak var table: NSTableView?
        private var rows: [Record] = []
        private var columnFields: [Field] = []
        private var sourceIDs: [Record.ID] = []

        init(_ parent: RecordTable) { self.parent = parent }

        func update(_ parent: RecordTable) {
            self.parent = parent
            guard let table else { return }
            if parent.fields != columnFields {
                columnFields = parent.fields
                table.tableColumns.forEach(table.removeTableColumn)
                table.sortDescriptors = []
                for f in parent.fields {
                    let col = NSTableColumn(identifier: .init(String(f.fieldID)))
                    col.title = f.displayName
                    col.width = Self.width(for: f)
                    col.minWidth = 40
                    col.sortDescriptorPrototype = NSSortDescriptor(key: String(f.fieldID), ascending: true)
                    table.addTableColumn(col)
                }
            }
            let ids = parent.records.map(\.id)
            if ids != sourceIDs {
                sourceIDs = ids
                rows = sorted(parent.records, by: table.sortDescriptors)
                table.reloadData()
            }
            syncSelection()
        }

        static func width(for f: Field) -> CGFloat {
            switch f.type {
            case .number, .date: 90
            case .flag: 50
            default: f.fieldID <= 3 ? 200 : 140
            }
        }

        private func sorted(_ recs: [Record], by descriptors: [NSSortDescriptor]) -> [Record] {
            guard let d = descriptors.first, let key = d.key, let fid = UInt16(key) else { return recs }
            return recs.sorted {
                d.ascending ? Value.sortLess($0.values[fid], $1.values[fid]) : Value.sortLess($1.values[fid], $0.values[fid])
            }
        }

        private func syncSelection() {
            guard let table else { return }
            let row = rows.firstIndex { $0.id == parent.selection } ?? -1
            if table.selectedRow != row {
                if row >= 0 {
                    table.selectRowIndexes([row], byExtendingSelection: false)
                    table.scrollRowToVisible(row)
                } else {
                    table.deselectAll(nil)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn, let fid = UInt16(col.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                f.cell?.truncatesLastVisibleLine = true
                return f
            }()
            let value = rows[row].values[fid]
            field.stringValue = value.map { $0.description.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ") } ?? ""
            field.alignment = { if case .number? = value { return .right } else { return .natural } }()
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let selected = parent.selection
            rows = sorted(parent.records, by: tableView.sortDescriptors)
            tableView.reloadData()
            parent.selection = selected
            syncSelection()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let id = table.selectedRow >= 0 ? rows[table.selectedRow].id : nil
            if id != parent.selection {
                DispatchQueue.main.async { self.parent.selection = id }
            }
        }
    }
}
