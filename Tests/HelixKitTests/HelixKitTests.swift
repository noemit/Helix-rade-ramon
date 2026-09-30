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

    init() throws { collection = try HelixCollection(url: Self.url) }

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
        let ev = AbacusEvaluator(collection: collection, relation: libros, records: recs)
        let alarcon = try #require(recs.first { $0.values[3] == .text("Capitán veneno.  El sombrero de tres picos") })
        #expect(ev.value(ofAbacus: 98, for: alarcon) == .text("Alarcón, Pedro Antonio de"))
        #expect(ev.value(ofAbacus: 25, for: alarcon) == .text("El Capitán veneno.  El sombrero de tres picos "))
        // "Nome Non Rep." blanks a name repeated from the previous record in index order.
        let i = try #require(recs.firstIndex(of: alarcon))
        #expect(ev.value(ofAbacus: 105, for: recs[i + 1]) == nil)
        #expect(ev.value(ofAbacus: 112, for: alarcon) == .number(2147))
        #expect(collection.formulaText(collection.abacus(id: 691)?.root) == "([Precio Merca] ÷ 166.386)")
    }

    @Test func queriesSelectRecords() throws {
        let ev = AbacusEvaluator(collection: collection, relation: libros, records: try collection.records(of: libros))
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
