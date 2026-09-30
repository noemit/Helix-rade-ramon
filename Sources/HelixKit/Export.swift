import Foundation

public enum Exporter {
    /// RFC 4180 CSV with a header row of field names.
    public static func csv(fields: [Field], records: [Record]) -> String {
        func esc(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = fields.map { esc($0.displayName) }.joined(separator: ",") + "\r\n"
        for r in records {
            out += fields.map { esc(r[$0]?.description ?? "") }.joined(separator: ",") + "\r\n"
        }
        return out
    }

    public struct HelixTextOptions {
        public enum Newlines: String, CaseIterable { case keep = "Keep", verticalTab = "Vertical tab", space = "Space" }
        public var fieldDelimiter: Character = "\t"
        public var recordDelimiter: Character = "\r"
        /// What to do with returns inside text values (they would otherwise end the record).
        public var newlines: Newlines = .verticalTab
        public var includeHeader = false
        public var encoding: String.Encoding = .utf8
        public init() {}
    }

    /// Text in Helix's import format: one record per line, fields separated by tabs, in the
    /// given field order (use a view template's tab order so Helix maps columns to it on import).
    /// Dates are written as d-m-yyyy and numbers without grouping.
    public static func helixText(fields: [Field], records: [Record], options: HelixTextOptions = .init()) -> String {
        let fd = String(options.fieldDelimiter), rd = String(options.recordDelimiter)
        func clean(_ s: String) -> String {
            var t = s.replacingOccurrences(of: fd, with: " ")
            let nl: String? = switch options.newlines {
            case .keep: nil
            case .verticalTab: "\u{0B}"
            case .space: " "
            }
            if let nl { t = t.replacingOccurrences(of: "\r\n", with: nl).replacingOccurrences(of: "\n", with: nl).replacingOccurrences(of: "\r", with: nl) }
            return rd == "\r" || rd == "\n" ? t : t.replacingOccurrences(of: rd, with: " ")
        }
        func text(_ v: Value?) -> String {
            switch v {
            case .number(let n)?: n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .flag(let b)?: b ? "Yes" : "No"
            case .picture?, .raw?, nil: ""
            case let v?: v.description
            }
        }
        var lines: [String] = []
        if options.includeHeader { lines.append(fields.map { clean($0.displayName) }.joined(separator: fd)) }
        for r in records { lines.append(fields.map { clean(text(r[$0])) }.joined(separator: fd)) }
        return lines.joined(separator: rd) + rd
    }

    /// JSON dump of the collection: schema plus all records (from `records`, e.g. the edited store).
    public static func json(_ collection: HelixCollection, records recordsOf: ((Relation) throws -> [Record])? = nil) throws -> Data {
        var rels: [[String: Any]] = []
        for rel in collection.relations {
            let records = try recordsOf?(rel) ?? collection.records(of: rel)
            rels.append([
                "name": rel.name,
                "fields": rel.fields.map { ["id": Int($0.fieldID), "name": $0.displayName, "type": $0.type.description] },
                "records": records.map { r -> [String: Any] in
                    var obj: [String: Any] = ["_id": Int(r.id)]
                    for f in rel.fields {
                        guard let v = r[f] else { continue }
                        switch v {
                        case .number(let n): obj[f.displayName] = n
                        case .flag(let b): obj[f.displayName] = b
                        case .picture(let d), .raw(let d): obj[f.displayName] = d.base64EncodedString()
                        default: obj[f.displayName] = v.description
                        }
                    }
                    return obj
                },
            ])
        }
        return try JSONSerialization.data(withJSONObject: ["collection": collection.name, "relations": rels],
                                          options: [.prettyPrinted, .sortedKeys])
    }
}
