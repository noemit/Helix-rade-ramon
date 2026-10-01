import Foundation
import Testing
@testable import HelixKit

/// Tests that need no sample data.
struct FormatTests {
    @Test func rejectsNonHelixData() {
        #expect(throws: HelixFormatError.self) { try HeapFile(data: Data(repeating: 0, count: 128)) }
    }

    @Test func julianDayConversion() {
        let c = HelixDate(julianDay: 2_451_545).components
        #expect(c.year == 2000 && c.month == 1 && c.day == 1)
    }

    @Test func dateHelpers() {
        #expect(HelixDate(year: 2000, month: 1, day: 1).julianDay == 2_451_545)
        #expect(AbacusEvaluator.parseDate("1-6-1986") == HelixDate(year: 1986, month: 6, day: 1))
    }
}

/// Tests against the private sample collection `Libros` at the repository root. It is not
/// committed (personal data), so these are skipped when the file is absent.
let librosURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Libros")

@Suite(.enabled(if: FileManager.default.fileExists(atPath: librosURL.path), "needs the private Libros sample file"))
struct LibrosTests {
    static let url = librosURL

    let collection: HelixCollection

    let design: Design

    init() throws {
        collection = try HelixCollection(url: Self.url)
        design = Design(model: DesignModel(importing: collection), collection: collection)
    }

    var libros: Relation { collection.relations.first { $0.name == "Libros" }! }

    @Test func schema() {
        #expect(collection.name == "Libros")
        #expect(collection.relations.map(\.name).sorted() == ["Autores", "Libros", "Sinopse"])
        #expect(libros.fields.count == 41)
        #expect(libros.field(withID: 14)?.name == "Indice")
        #expect(libros.dataID == 0x4698)
        #expect(libros.field(withID: 3)?.name == "Título")
        #expect(libros.field(withID: 25)?.type == .number)
        #expect(libros.field(withID: 40)?.type == .date)
        #expect(libros.field(withID: 36)?.type == .flag)
    }

    @Test func allRecordsParse() throws {
        let records = try collection.records(of: libros)
        #expect(records.count == 2147)
        #expect(records.count == libros.recordCount)
        #expect(Set(records.map(\.id)).count == records.count)
    }

    @Test func knownRecordValues() throws {
        let records = try collection.records(of: libros)
        let r = try #require(records.first { $0.id == 0x102 })
        #expect(r.values[1] == .text("Livy"))
        #expect(r.values[3] == .text("War with Hannibal"))
        #expect(r.values[25] == .number(1979))

        // MacRoman accented text, UTF-8 (0xFFFC) text, and dates.
        #expect(records.contains { $0.values[6]?.text?.contains("Bruño") == true })
        #expect(records.contains { $0.values[2]?.text == "Joāo" })
        let dates = records.compactMap { r -> HelixDate? in
            if case .date(let d)? = r.values[40] { d } else { nil }
        }
        #expect(dates.count == 24)
        #expect(dates.allSatisfy { $0.components.year == 2026 })
    }

    @Test func fontTable() {
        #expect(collection.fontTable.count == 10)
        #expect(collection.fontTable[5] == "Lucida Grande")
        #expect(collection.fontTable[6] == "Palatino Bold")
    }

    @Test func everyTemplateParses() {
        for obj in collection.objects.objects(ofKind: .template) {
            #expect(collection.template(id: obj.id) != nil, "template \(obj.name)")
        }
    }

    @Test func fichaNovaLayout() throws {
        let t = try #require(collection.template(id: 1086))
        #expect(t.name == "Ficha nova")
        #expect(t.repeatElement == nil)
        let flat = t.elements
        #expect(flat.count == 67)
        let autor = try #require(flat.first { $0.content == .label("Autor:") })
        #expect(autor.rect == HelixRect(top: 9, left: 1, bottom: 33, right: 71))
        #expect(autor.font.family == "Palatino Bold" && autor.font.size == 16)
        let apelido = try #require(flat.first { $0.content == .data(fieldObjectID: 16, abacusObjectID: nil) })
        #expect(apelido.font.family == "Lucida Grande" && apelido.font.bold)
        #expect(flat.contains { $0.content == .data(fieldObjectID: 385, abacusObjectID: 386) })
    }

    @Test func listTemplateHasRepeat() throws {
        let t = try #require(collection.template(id: 510))
        let rep = try #require(t.repeatElement)
        #expect(rep.rect == HelixRect(top: 47, left: 5, bottom: 98, right: 1276))
        guard case .repeatGroup(let rows) = rep.content else { Issue.record("not a repeat"); return }
        #expect(rows.count == 5)
    }

    @Test func viewsAndIndexOrder() throws {
        let views = collection.views(in: libros)
        #expect(views.count == 30)
        let lista = try #require(views.first { $0.name == "Lista por título" })
        #expect(lista.templateID == 510)
        #expect(collection.objects[try #require(lista.indexID)]?.name == "Título")
        let ordered = try collection.records(of: libros, orderedByIndex: lista.indexID)
        #expect(ordered.count == 2147)
        #expect(ordered.first?.values[3] == .text("100 artigos"))
    }

    @Test func abaciEvaluate() throws {
        let recs = try collection.records(of: libros, orderedByIndex: 21)
        let ev = AbacusEvaluator(design: design, relation: libros, records: recs)
        let alarcon = try #require(recs.first { $0.values[3] == .text("Capitán veneno.  El sombrero de tres picos") })
        #expect(ev.value(ofAbacus: 98, for: alarcon) == .text("Alarcón, Pedro Antonio de"))
        #expect(ev.value(ofAbacus: 25, for: alarcon) == .text("El Capitán veneno.  El sombrero de tres picos "))
        // "Nome Non Rep." blanks a name repeated from the previous record in index order.
        let i = try #require(recs.firstIndex(of: alarcon))
        #expect(ev.value(ofAbacus: 105, for: recs[i + 1]) == nil)
        #expect(ev.value(ofAbacus: 112, for: alarcon) == .number(2147))
        #expect(collection.formulaText(collection.abacus(id: 691)?.root) == "[Precio Merca] ÷ 166.386")
    }

    @Test func queriesSelectRecords() throws {
        let ev = AbacusEvaluator(design: design, relation: libros, records: try collection.records(of: libros))
        #expect(ev.select(query: 148).count == 183) // Poesía
        #expect(ev.select(query: 118).count == 2147) // Query (all records)
    }

    @Test func helixTextExport() throws {
        let t = try #require(collection.template(id: 1086))
        let order = t.fieldOrder.compactMap { libros.field(objectID: $0) }
        #expect(order.count == Set(order.map(\.id)).count)
        #expect(order.count >= 35)
        let recs = try collection.records(of: libros)
        let text = Exporter.helixText(fields: order, records: recs)
        let lines = text.split(separator: "\r", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 2147)
        #expect(lines.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == order.count })
        #expect(!text.contains("\n"))
    }

    @Test func rectangleFlagsAndFormats() throws {
        let t = try #require(collection.template(id: 1086))
        func el(_ fieldObjectID: Int) throws -> TemplateElement {
            try #require(t.elements.first { if case .data(fieldObjectID?, _) = $0.content { true } else { false } })
        }
        // Matches Helix: Faltas and Foto are framed, EXLIBRIS is not; Comentarios scrolls.
        #expect(try el(250).framed && el(706).framed && !el(443).framed)
        #expect(try el(10).scrollsVertically && !el(11).scrollsVertically)
        #expect(t.elements.first { $0.content == .label("Data ficha") }?.framed == true)
        // "Precio Euros" shows 19,95 and "Precio Pesetas despois 2002" shows 3.319Pts in Spanish Helix.
        let es = Locale(identifier: "es_ES")
        #expect(try el(704).format.string(19.95, locale: es, currencySymbol: "Pts") == "19,95")
        #expect(try el(53).format.string(3319.4007, locale: es, currencySymbol: "Pts") == "3.319Pts")
    }

    @Test func formulasRoundTrip() throws {
        // Every abacus prints to text that parses back to the same tile tree.
        for rel in design.relations {
            for a in design.abaci(in: rel) {
                let text = design.formulaText(a.root)
                guard let root = a.root else { continue }
                let parsed = try design.parseFormula(text, in: rel)
                #expect(parsed.structure == root.structure, "\(a.name): \(text)")
            }
        }
        let rel = libros
        let tituloLista = design.formulaText(design.abacus(id: 25)?.root)
        #expect(tituloLista.hasPrefix("if undefined([Artigo]) then"))
        let t = try design.parseFormula("if [Ano merca] >= 2002 then [Precio Euros] * 166.386 else empty", in: rel)
        #expect(design.formulaText(t) == "if [Ano merca] ≥ 2002 then [Precio Euros] × 166.386 else empty")
        #expect(throws: Formula.ParseError.self) { try design.parseFormula("[Nope] & 1", in: rel) }
        #expect(throws: Formula.ParseError.self) { try design.parseFormula("text(1, 2)", in: rel) }
    }

    @Test func extraFormulaFunctions() throws {
        let d = Design(model: design.model, collection: collection)
        let rel = libros
        func eval(_ f: String, _ r: Record = Record(id: 1, values: [3: .text("  Home ao pairo "), 25: .number(1979)])) throws -> Value? {
            let tile = try d.parseFormula(f, in: rel)
            let aid = d.update { $0.addAbacus(to: rel.id, name: "t\(UUID().uuidString)", root: tile, showIcon: false)! }
            return AbacusEvaluator(design: d, relation: d.relation(id: rel.id)!, records: [r]).value(ofAbacus: aid, for: r)
        }
        #expect(try eval("upper(trim([Título]))") == .text("HOME AO PAIRO"))
        #expect(try eval("length(trim([Título]))") == .number(13))
        #expect(try eval("left(trim([Título]), 4) & mid(trim([Título]), 6, 2)") == .text("Homeao"))
        #expect(try eval("right(trim([Título]), 5)") == .text("pairo"))
        #expect(try eval("round(166.386 * 2, 1)") == .number(332.8))
        #expect(try eval("[Ano merca] > 1970 and not([Ano merca] > 2000)") == .flag(true))
        #expect(try eval("[Ano merca] < 1900 or trim([Título]) ends with \"pairo\"") == .flag(true))
        #expect(try eval("max(3, [Ano merca]) − min(3, 4)") == .number(1976))
        #expect(try eval("weekday(makedate(1, 10, 2026))") == .number(4)) // 1 Oct 2026 is a Thursday
        let text = d.formulaText(try d.parseFormula("[Ano merca] > 1970 and not([Ano merca] > 2000) or abs(-3) = 3", in: rel))
        #expect(text == "(([Ano merca] > 1970) and not([Ano merca] > 2000)) or (abs(-3) = 3)")
    }

    @Test func importedDesignMatchesHelix() throws {
        let m = design.model
        let rd = try #require(m.relations.first { $0.name == "Libros" })
        #expect(rd.fields.count == 41 && rd.views.count == 30 && rd.templates.count >= 18)
        #expect(rd.queries.count == 20 && rd.indexes.count == 10)
        #expect(rd.queries.allSatisfy { $0.abacusID.flatMap(design.abacus(id:)) != nil })
        // Survives JSON storage.
        let back = try JSONDecoder().decode(DesignModel.self, from: JSONEncoder().encode(m))
        #expect(back == m)
        // Ordering through the design matches the Helix B-tree.
        let ordered = design.order(try collection.records(of: libros), relation: libros, byIndex: 22)
        #expect(ordered.first?.values[3] == .text("100 artigos"))
    }

    @Test func designEditing() throws {
        let d = Design(model: design.model, collection: collection)
        let rel = libros
        let fid = try #require(d.update { $0.addField(to: rel.id, name: "Notas", type: .text) })
        #expect(d.relation(id: rel.id)?.fields.contains { $0.name == "Notas" && $0.fieldID == 42 } == true)
        #expect(d.relation(id: rel.id)?.iconIDs.contains(fid) == true)
        let aid = try #require(d.update { $0.addAbacus(to: rel.id, name: "Notas maiúsculas", root: nil) })
        let tile = try d.parseFormula("[Notas] & \"!\"", in: d.relation(id: rel.id)!)
        d.update { $0.setAbacus(Abacus(id: aid, name: "Notas maiúsculas", root: tile)) }
        let ev = AbacusEvaluator(design: d, relation: d.relation(id: rel.id)!, records: [])
        #expect(ev.value(ofAbacus: aid, for: Record(id: 1, values: [42: .text("Ola")])) == .text("Ola!"))
        let tid = try #require(d.update { $0.addTemplate(to: rel.id, name: "Nova", fields: d.relation(id: rel.id)!.fields.prefix(3).map { $0 }) })
        #expect(d.template(id: tid)?.elements.count == 6)
        let vid = try #require(d.update { $0.addView(to: rel.id, name: "Vista nova", templateID: tid) })
        #expect(d.views(in: d.relation(id: rel.id)!).contains { $0.id == vid })
        let qid = try #require(d.update { $0.addQuery(to: rel.id, name: "Só poesía") })
        let q = try #require(d.query(id: qid))
        let poesia = try d.parseFormula("[Clasificación] contains \"Poesía\"", in: rel)
        d.update { $0.setAbacus(Abacus(id: q.abacusID!, name: "", root: poesia)) }
        let all = try collection.records(of: rel)
        #expect(AbacusEvaluator(design: d, relation: rel, records: all).select(query: qid).count == 183)
        // Edited index keys drop the Helix B-tree and sort by value.
        var idx = try #require(d.index(id: 22))
        idx.keys = [16]
        d.update { $0.setIndex(idx) }
        #expect(d.index(id: 22)?.helixNumber == nil)
        let byApelido = d.order(all, relation: rel, byIndex: 22).compactMap { $0.values[1]?.text }
        #expect(byApelido.first == "A Voz de Galicia ed.")
        d.update { $0.rename(fid, to: "Notas persoais"); $0.delete(vid) }
        #expect(d.name(of: fid) == "Notas persoais" && d.view(id: vid) == nil)
        let copy = try #require(d.update { $0.duplicate(tid) })
        #expect(d.template(id: copy)?.name == "Nova copy")
    }

    @Test func forgivingSearch() throws {
        let recs = try collection.records(of: libros)
        func find(_ q: String) -> Set<UInt32> {
            let words = TextSearch.words(q)
            return Set(recs.filter { TextSearch.matches(TextSearch.haystack(for: $0, in: libros), query: words) }.map(\.id))
        }
        let a = find("Chao Rego, Xosé"), b = find("Xosé Chao Rego"), c = find("xose chao rego")
        #expect(a.count == 3 && a == b && b == c)
        #expect(!find("Cunqueiro taberna Galiana").isEmpty && find("Cunqueiro taberna Galiana").count <= find("Cunqueiro").count)
        #expect(TextSearch.same(.text("Chao Rego, Xosé"), .text("chao rego xose")))
    }

    @Test func findByForm() throws {
        let recs = try collection.records(of: libros)
        let lugar = try #require(libros.fields.first { $0.name == "Lugar" })
        let data = try #require(libros.fields.first { $0.name == "Data" })
        let euros = try #require(libros.fields.first { $0.name == "Precio Euros" })
        let vigo = recs.filter { FindCriteria.matches($0[lugar], "vigo", type: lugar.type) && FindCriteria.matches($0[data], "> 1990", type: data.type) }
        #expect(vigo.count == 143)
        #expect(recs.filter { FindCriteria.matches($0[euros], "=", type: euros.type) }.count == 873)
        #expect(FindCriteria.matches(.number(19.95), "≥ 19,95", type: .number))
        #expect(!FindCriteria.matches(.text("Santiago de Compostela"), "= Santiago", type: .text))
        #expect(FindCriteria.matches(.date(HelixDate(year: 2026, month: 9, day: 17)), "< 1-10-2026", type: .date))
    }

    @Test func drillDownSeesRepeatedNames() throws {
        // "Nome Non Rep." is blank when the previous row has the same author; with
        // ignorePrevious every record shows its author, so clicking an author can match them all.
        let recs = try collection.records(of: libros, orderedByIndex: 21)
        let ev = AbacusEvaluator(design: design, relation: libros, records: recs)
        let i = try #require(recs.firstIndex { ev.value(ofAbacus: 98, for: $0)?.text == "Alarcón, Pedro Antonio de" })
        #expect(ev.value(ofAbacus: 105, for: recs[i + 1]) == nil)
        ev.ignorePrevious = true
        let author = ev.value(ofAbacus: 105, for: recs[i])
        #expect(ev.value(ofAbacus: 105, for: recs[i + 1]) == author)
        #expect(recs.filter { TextSearch.same(ev.value(ofAbacus: 105, for: $0), author) }.count >= 2)
    }

    @Test func templateEditing() throws {
        var t = try #require(design.template(id: 510))
        let rep = try #require(t.repeatElement)
        let field = try #require(TemplateElement.flatten(t.elements).first { e in
            if case .data(16?, _) = e.content { true } else { false }
        })
        // Dragging a field out of the repeat rectangle moves it to the page, and back again.
        t.move(field.id, dx: 0, dy: 300)
        #expect(!TemplateElement.flatten(t.repeatElement.map { [$0] } ?? []).contains { $0.id == field.id })
        #expect(t.element(field.id)?.rect.top == field.rect.top + 300)
        t.move(field.id, dx: 0, dy: -300)
        if case .repeatGroup(let kids) = t.repeatElement!.content { #expect(kids.contains { $0.id == field.id }) }
        // Moving the repeat rectangle carries its contents.
        t.move(rep.id, dx: 10, dy: 20)
        #expect(t.element(field.id)?.rect.left == field.rect.left + 10)
        t.update(field.id) { $0.framed = true; $0.font.size = 20 }
        #expect(t.element(field.id)?.framed == true && t.element(field.id)?.font.size == 20)
        t.remove(field.id)
        #expect(t.element(field.id) == nil)
        var form = try #require(design.template(id: 1086))
        form.makeList(id: 999_999)
        #expect(form.repeatElement?.id == 999_999)
    }

    @Test func updateFromHelixKeepsFaulixEdits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("faulix-merge-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try RecordStore(url: url)
        try store.importIfNeeded(from: collection)
        let recs = try store.records(ofRelation: libros.id)
        let (a, b, c) = (recs[0], recs[1], recs[2])
        try store.delete(recordID: a.id, relationID: libros.id)                       // deleted in Faulix
        var bb = b; bb.values[3] = .text("changed by an old import")
        try store.put(bb, recordID: b.id, relationID: libros.id, userEdit: false)       // not a user edit
        var cc = c; cc.values[3] = .text("Ramón's own title")
        try store.save(cc, relationID: libros.id)                                       // user edit
        let newID = try store.nextRecordID(relationID: libros.id)
        try store.save(Record(id: newID, values: [3: .text("Only in Faulix")]), relationID: libros.id)
        var m = design.model
        let report = try store.merge(from: collection, original: collection, design: &m)
        #expect(report.updated == 1 && report.added == 0 && report.deleted == 0 && report.conflicts.isEmpty)
        #expect(try store.record(a.id, relationID: libros.id) == nil)
        #expect(try store.record(b.id, relationID: libros.id)?.values == b.values)
        #expect(try store.record(c.id, relationID: libros.id)?.values[3] == .text("Ramón's own title"))
        #expect(try store.record(newID, relationID: libros.id) != nil)
        #expect(try store.backupIfNeeded(force: true) != nil)
        #expect(try store.backupIfNeeded() == nil)
        try? FileManager.default.removeItem(at: store.backupFolder)
    }

    @Test func designPersistsInStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("faulix-design-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try RecordStore(url: url)
        #expect(store.loadDesign() == nil)
        var m = design.model
        m.addField(to: libros.id, name: "Notas", type: .text)
        try store.saveDesign(m, note: "New Field")
        #expect(store.loadDesign() == m)
        #expect(try store.history().first?.action == .design)
    }

    @Test func recordStoreRoundTripAndEdits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nothelix-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try RecordStore(url: url)
        try store.importIfNeeded(from: collection)
        #expect(store.isImported)
        let original = try collection.records(of: libros)
        var stored = try store.records(ofRelation: libros.id)
        #expect(stored.count == 2147)
        #expect(Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.values) })
            == Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.values) }))

        // Edit a title and add a record; both must be slotted into Título index order.
        let titulo = try #require(libros.field(withID: 3))
        var r = try #require(stored.first { $0.values[3] == .text("Home ao pairo") })
        r[titulo] = .text("Zzz edited title")
        try store.save(r, relationID: libros.id)
        let newID = try store.nextRecordID(relationID: libros.id)
        try store.save(Record(id: newID, values: [3: .text("Aaa new book")]), relationID: libros.id)
        stored = try store.records(ofRelation: libros.id)
        #expect(stored.count == 2148)
        let modified = try store.modifiedRecordIDs(ofRelation: libros.id)
        #expect(modified == [r.id, newID])
        let ordered = collection.order(stored, relation: libros, byIndex: 411, modified: modified)
        let titles = ordered.compactMap { $0.values[3]?.text }
        let aaa = try #require(titles.firstIndex(of: "Aaa new book"))
        #expect(titles[aaa + 1].localizedStandardCompare("Aaa") != .orderedAscending)
        let zzz = try #require(titles.firstIndex(of: "Zzz edited title"))
        #expect(titles[zzz - 1].localizedStandardCompare("Zzz edited title") != .orderedDescending)

        try store.delete(recordID: newID, relationID: libros.id)
        #expect(try store.records(ofRelation: libros.id).count == 2147)

        // History: newest first, with before/after snapshots that can be restored.
        let log = try store.history()
        #expect(log.map(\.action) == [.delete, .insert, .update])
        #expect(log[2].changedFields == [3])
        #expect(log[2].before?.values[3] == .text("Home ao pairo"))
        try store.put(log[2].before, recordID: log[2].recordID, relationID: libros.id, note: "Undo")
        #expect(try store.record(r.id, relationID: libros.id)?.values[3] == .text("Home ao pairo"))
        #expect(try store.history().first?.note == "Undo")
        // Saving an identical record logs nothing.
        let current = try #require(try store.record(r.id, relationID: libros.id))
        #expect(try store.save(current, relationID: libros.id) == nil)
    }
}
