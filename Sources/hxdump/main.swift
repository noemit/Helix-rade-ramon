import Foundation
import HelixKit

let usage = """
usage: hxdump <collection> [schema|objects|records <relation> [limit]|csv <relation>|json|templates|views]
"""

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

do {
    let collection = try HelixCollection(url: URL(fileURLWithPath: args[1]))
    let command = args.count > 2 ? args[2] : "schema"

    func relation(_ name: String?) throws -> Relation {
        guard let rel = collection.relations.first(where: { $0.name == name }) ?? (name == nil ? collection.relations.first : nil) else {
            throw HelixFormatError("No relation named \(name ?? "?")")
        }
        return rel
    }

    switch command {
    case "schema":
        print("Collection: \(collection.name)  (\(collection.objects.objects.count) live objects)")
        for rel in collection.relations {
            print("\nRelation '\(rel.name)'  dataID=0x\(String(rel.dataID, radix: 16))  records=\(rel.recordCount)  indexes=\(rel.indexes.count)")
            for f in rel.fields {
                print(String(format: "  #%-3d %-40@ %@", f.fieldID, f.displayName as NSString, f.type.description as NSString))
            }
            var byKind: [String: [String]] = [:]
            for obj in collection.objects(in: rel) where obj.kind != .field {
                byKind[obj.kind?.pluralName ?? "kind \(obj.rawKind)", default: []].append(obj.name.isEmpty ? "#\(obj.id)" : obj.name)
            }
            for (k, names) in byKind.sorted(by: { $0.key < $1.key }) {
                print("  \(k) (\(names.count)): \(names.joined(separator: ", "))")
            }
        }
    case "objects":
        for obj in collection.objects.objects.values.sorted(by: { $0.id < $1.id }) {
            print("\(obj.id)\t\(obj.kind?.displayName ?? "kind \(obj.rawKind)")\tblock=\(obj.block)\tlen=\(obj.length)\t\(obj.name)")
        }
    case "records":
        let rel = try relation(args.count > 3 ? args[3] : nil)
        let limit = args.count > 4 ? Int(args[4]) ?? .max : .max
        for r in try collection.records(of: rel).prefix(limit) {
            print("— record \(r.id)")
            for f in rel.fields {
                if let v = r[f] { print("  \(f.displayName): \(v.description.replacingOccurrences(of: "\n", with: "⏎"))") }
            }
        }
    case "csv":
        let rel = try relation(args.count > 3 ? args[3] : nil)
        print(Exporter.csv(fields: rel.fields, records: try collection.records(of: rel)), terminator: "")
    case "templates":
        func name(_ id: Int?) -> String { id.flatMap { collection.objects[$0]?.name } ?? "-" }
        func show(_ els: [TemplateElement], indent: String) {
            for e in els.sorted(by: { ($0.rect.top, $0.rect.left) < ($1.rect.top, $1.rect.left) }) {
                let r = e.rect, f = e.font
                let geo = "[\(r.top),\(r.left) \(r.width)x\(r.height)] \(f.family ?? "system") \(f.size) s\(f.style) \(e.alignment)"
                switch e.content {
                case .label(let t): print("\(indent)label \(geo) \"\(t.replacingOccurrences(of: "\n", with: "⏎"))\"")
                case .data(let fid, let aid): print("\(indent)data  \(geo) field=\(name(fid)) abacus=\(name(aid))")
                case .repeatGroup(let c): print("\(indent)repeat [\(r.top),\(r.left) \(r.width)x\(r.height)]"); show(c, indent: indent + "  ")
                case .group(let c): print("\(indent)group [\(r.top),\(r.left) \(r.width)x\(r.height)]"); show(c, indent: indent + "  ")
                }
            }
        }
        for obj in collection.objects.objects(ofKind: .template) {
            guard let t = collection.template(id: obj.id) else { print("\n#\(obj.id) \(obj.name): <unparsed>"); continue }
            print("\nTemplate #\(t.id) '\(t.name)' page \(t.page.width)x\(t.page.height)")
            show(t.elements, indent: "  ")
        }
    case "views":
        func name(_ id: Int?) -> String { id.flatMap { collection.objects[$0]?.name } ?? "-" }
        for rel in collection.relations {
            for v in collection.views(in: rel) {
                print("\(rel.name) / \(v.name): template=\(name(v.templateID)) query=\(name(v.queryID)) index=\(name(v.indexID)) window=\(v.window.width)x\(v.window.height)")
            }
        }
    case "abaci":
        for rel in collection.relations {
            let recs = try collection.records(of: rel, orderedByIndex: collection.objects(in: rel, kind: .index).first?.id)
            let ev = AbacusEvaluator(collection: collection, relation: rel, records: recs)
            let sample = args.count > 3 ? recs.first { String($0.id) == args[3] } : recs.first
            print("\nRelation '\(rel.name)'" + (sample.map { " (values for record \($0.id))" } ?? ""))
            for obj in collection.objects(in: rel, kind: .abacus) {
                guard let a = collection.abacus(id: obj.id) else { continue }
                let v = ev.value(ofAbacus: a.id, for: sample).map { "\($0)".replacingOccurrences(of: "\n", with: "⏎") } ?? "∅"
                print("  \(a.name.isEmpty ? "#\(a.id)" : a.name) = \(collection.formulaText(a.root))\n      → \(v)")
            }
        }
    case "json":
        FileHandle.standardOutput.write(try Exporter.json(collection))
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
