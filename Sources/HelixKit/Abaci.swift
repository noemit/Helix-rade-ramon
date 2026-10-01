import Foundation

/// A node of an abacus (formula) tile tree.
///
/// Abacus objects hold `u16 tileCount` at `+0x5A` followed by `{u32 ref, i16, i16}`
/// per top-level tile; the first one is the root. Operator tiles (kind 18) store the
/// opcode at `+6`, `u16 operandCount` at `+0x20` and operand refs from `+0x22`
/// (0 = empty slot). Constant tiles (kind 19) store the type at `+4` (0 text,
/// 1 number, 2 date, 3 flag), the binary value from `+6` and display text as a
/// Pascal string at `+0xE`.
public indirect enum Tile: Hashable, Codable {
    case field(objectID: Int)
    case abacus(objectID: Int)
    case constant(Value?)
    case op(Opcode, [Tile], tileID: Int)
    case empty
}

/// Helix operator tiles. Meanings are inferred from how the sample collection uses
/// them; the ones marked (?) are best guesses.
public enum Opcode: Hashable, Codable, CustomStringConvertible {
    case add, subtract, multiply, divide
    case textOf, numberOf, dateOf
    case returnCharacter
    case startsWith, contains
    case followedBy
    case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
    case ifThenElse, isDefined, isUndefined, defaultValue
    case flagValue
    case currentDate, dayOf, monthOf, yearOf
    case total, maximum, count, previous
    case unknown(UInt16)

    init(code: UInt16) {
        switch code {
        case 0x00: self = .add
        case 0x01: self = .subtract
        case 0x02: self = .multiply
        case 0x03: self = .divide
        case 0x04: self = .textOf
        case 0x06: self = .numberOf
        case 0x08: self = .dateOf
        case 0x0F: self = .returnCharacter
        case 0x12: self = .startsWith // (?)
        case 0x13: self = .contains
        case 0x17: self = .followedBy
        case 0x19: self = .equal
        case 0x1A: self = .notEqual // (?)
        case 0x1B: self = .less // (?)
        case 0x1C: self = .lessOrEqual // (?)
        case 0x1D: self = .greater // (?)
        case 0x1E: self = .greaterOrEqual // (?)
        case 0x26: self = .ifThenElse
        case 0x27: self = .isDefined
        case 0x28: self = .isUndefined
        case 0x29: self = .defaultValue
        case 0x2E: self = .flagValue // (?)
        case 0x41: self = .currentDate
        case 0x43: self = .dayOf
        case 0x44: self = .monthOf
        case 0x45: self = .yearOf
        case 0x55: self = .total
        case 0x5B: self = .maximum
        case 0x62: self = .count
        case 0x6C: self = .previous // (?)
        default: self = .unknown(code)
        }
    }

    public var description: String {
        switch self {
        case .add: "+"
        case .subtract: "−"
        case .multiply: "×"
        case .divide: "÷"
        case .textOf: "text of"
        case .numberOf: "number of"
        case .dateOf: "date of"
        case .returnCharacter: "return"
        case .startsWith: "starts with"
        case .contains: "contains"
        case .followedBy: "followed by"
        case .equal: "="
        case .notEqual: "≠"
        case .less: "<"
        case .lessOrEqual: "≤"
        case .greater: ">"
        case .greaterOrEqual: "≥"
        case .ifThenElse: "if"
        case .isDefined: "defined"
        case .isUndefined: "undefined"
        case .defaultValue: "default"
        case .flagValue: "flag"
        case .currentDate: "current date"
        case .dayOf: "day of"
        case .monthOf: "month of"
        case .yearOf: "year of"
        case .total: "total"
        case .maximum: "maximum"
        case .count: "count"
        case .previous: "previous"
        case .unknown(let c): "op\(String(c, radix: 16))"
        }
    }

    var isAggregate: Bool { [.total, .maximum, .count].contains(self) }
}

public struct Abacus: Identifiable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var root: Tile?

    public init(id: Int, name: String, root: Tile?) {
        (self.id, self.name, self.root) = (id, name, root)
    }
}

extension HelixCollection {
    public func abacus(id: Int) -> Abacus? {
        guard let obj = objects[id], obj.kind == .abacus else { return nil }
        let o = heap.offset(ofBlock: obj.block)
        var visited = Set<Int>()
        let root = heap.u16(o + 0x5A) > 0 ? ref(o + 0x5C).map { tile($0, visited: &visited) } : nil
        return Abacus(id: id, name: obj.name, root: root)
    }

    private func tile(_ id: Int, visited: inout Set<Int>) -> Tile {
        guard let obj = objects[id] else { return .empty }
        let o = heap.offset(ofBlock: obj.block)
        switch obj.kind {
        case .field: return .field(objectID: id)
        case .abacus: return .abacus(objectID: id)
        case .constantTile:
            switch heap.u8(o + 4) {
            case 0: return .constant(.text(TextDecoding.name(heap.slice(o + 0xF, Int(heap.u8(o + 0xE))))))
            case 1: return .constant(.number(heap.f64(o + 6)))
            case 2: return .constant(.date(HelixDate(julianDay: Int(heap.u32(o + 6)), seconds: Int(heap.u32(o + 10)))))
            case 3: return .constant(.flag(heap.u8(o + 6) != 0))
            default: return .constant(nil)
            }
        case .operatorTile:
            guard visited.insert(id).inserted else { return .empty }
            let args = (0..<Int(heap.u16(o + 0x20))).map { i in
                ref(o + 0x22 + i * 4).map { tile($0, visited: &visited) } ?? .empty
            }
            return .op(Opcode(code: heap.u16(o + 6)), args, tileID: id)
        default: return .empty
        }
    }

    /// The formula as editable text (see `Formula`).
    public func formulaText(_ tile: Tile?) -> String {
        Formula.print(tile) { [objects] in objects[$0]?.name }
    }

    /// The abacus used by a query icon to select records.
    public func queryAbacusID(ofQuery id: Int) -> Int? {
        guard let obj = objects[id], obj.kind == .query else { return nil }
        return ref(heap.offset(ofBlock: obj.block) + 0x44).flatMap { objects[$0]?.kind == .abacus ? $0 : nil }
    }
}

/// Evaluates abaci for records of one relation. `records` is the record set of the
/// current view: summary tiles aggregate over it and `previous` looks back in it.
public final class AbacusEvaluator {
    public let design: Design
    public let relation: Relation
    public private(set) var records: [Record]
    public var today = Date()

    private var abaci: [Int: Abacus] = [:]
    private var aggregates: [Int: Value?] = [:]
    private var positions: [UInt32: Int] = [:]
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    public init(design: Design, relation: Relation, records: [Record]) {
        self.design = design
        self.relation = relation
        self.records = records
        positions = Dictionary(records.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func abacus(_ id: Int) -> Abacus? {
        if let a = abaci[id] { return a }
        let a = design.abacus(id: id)
        abaci[id] = a
        return a
    }

    public func value(ofAbacus id: Int, for record: Record?) -> Value? {
        var depth = 0
        return eval(abacus(id)?.root, record, &depth)
    }

    /// Records for which the query's abacus evaluates to true.
    public func select(query id: Int) -> [Record] {
        guard let aid = design.queryAbacusID(ofQuery: id) ?? (design.kind(of: id) == .abacus ? id : nil) else {
            return records
        }
        return records.filter { if case .flag(true)? = value(ofAbacus: aid, for: $0) { true } else { false } }
    }

    private func eval(_ tile: Tile?, _ record: Record?, _ depth: inout Int) -> Value? {
        guard let tile, depth < 64 else { return nil }
        depth += 1
        defer { depth -= 1 }
        switch tile {
        case .empty: return nil
        case .constant(let v): return v
        case .field(let id):
            guard let record, let f = relation.field(objectID: id) else { return nil }
            if case .text(let s)? = record[f], s.isEmpty { return nil }
            return record[f]
        case .abacus(let id):
            return eval(abacus(id)?.root, record, &depth)
        case .op(let op, let args, let tileID):
            if op.isAggregate {
                if let cached = aggregates[tileID] { return cached }
                let v = aggregate(op, args.first, &depth)
                aggregates[tileID] = v
                return v
            }
            if op == .previous {
                guard let record, let i = positions[record.id], i > 0 else { return nil }
                return eval(args.first, records[i - 1], &depth)
            }
            if op == .ifThenElse, args.count == 3 {
                guard case .flag(let c)? = eval(args[0], record, &depth) else { return nil }
                return eval(args[c ? 1 : 2], record, &depth)
            }
            if op == .defaultValue, args.count == 2 {
                return eval(args[0], record, &depth) ?? eval(args[1], record, &depth)
            }
            let v = args.map { eval($0, record, &depth) }
            return apply(op, v)
        }
    }

    private func aggregate(_ op: Opcode, _ arg: Tile?, _ depth: inout Int) -> Value? {
        if op == .count { return .number(Double(records.count)) }
        let nums = records.compactMap { r -> Double? in if case .number(let n)? = eval(arg, r, &depth) { n } else { nil } }
        switch op {
        case .total: return .number(nums.reduce(0, +))
        case .maximum: return nums.max().map(Value.number)
        default: return nil
        }
    }

    private func apply(_ op: Opcode, _ v: [Value?]) -> Value? {
        func num(_ x: Value?) -> Double? {
            switch x {
            case .number(let n)?: n
            case .text(let s)?: Self.parseNumber(s)
            default: nil
            }
        }
        func text(_ x: Value?) -> String { x.map { Self.text($0) } ?? "" }
        func date(_ x: Value?) -> Date? { if case .date(let d)? = x { d.date } else { nil } }
        func compare(_ a: Value?, _ b: Value?) -> ComparisonResult? {
            switch (a, b) {
            case (nil, _), (_, nil): return nil
            case let (.date(x)?, .date(y)?): return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
            case let (.flag(x)?, .flag(y)?): return x == y ? .orderedSame : !x ? .orderedAscending : .orderedDescending
            default:
                if let x = num(a), let y = num(b), !(a?.text != nil && b?.text != nil) {
                    return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
                }
                return text(a).compare(text(b), options: [.caseInsensitive])
            }
        }
        let a = v.first ?? nil, b = v.count > 1 ? v[1] : nil
        switch op {
        case .add:
            if case .date(let d)? = a, let n = num(b) { return .date(HelixDate(julianDay: d.julianDay + Int(n), seconds: d.seconds)) }
            return num(a).flatMap { x in num(b).map { .number(x + $0) } }
        case .subtract:
            if case .date(let x)? = a, case .date(let y)? = b { return .number(Double(x.julianDay - y.julianDay)) }
            if case .date(let d)? = a, let n = num(b) { return .date(HelixDate(julianDay: d.julianDay - Int(n), seconds: d.seconds)) }
            return num(a).flatMap { x in num(b).map { .number(x - $0) } }
        case .multiply: return num(a).flatMap { x in num(b).map { .number(x * $0) } }
        case .divide:
            guard let x = num(a), let y = num(b), y != 0 else { return nil }
            return .number(x / y)
        case .textOf: return a.map { .text(Self.text($0)) }
        case .numberOf: return num(a).map(Value.number)
        case .dateOf:
            if case .date? = a { return a }
            return a.flatMap { Self.parseDate(text($0)) }.map(Value.date)
        case .returnCharacter: return .text("\n")
        case .startsWith:
            guard a != nil, b != nil else { return nil }
            return .flag(text(a).range(of: text(b), options: [.caseInsensitive, .anchored]) != nil)
        case .contains:
            guard a != nil, b != nil else { return nil }
            return .flag(text(a).range(of: text(b), options: .caseInsensitive) != nil)
        case .followedBy: return .text(text(a) + text(b))
        case .equal: return compare(a, b).map { .flag($0 == .orderedSame) }
        case .notEqual: return compare(a, b).map { .flag($0 != .orderedSame) }
        case .less: return compare(a, b).map { .flag($0 == .orderedAscending) }
        case .lessOrEqual: return compare(a, b).map { .flag($0 != .orderedDescending) }
        case .greater: return compare(a, b).map { .flag($0 == .orderedDescending) }
        case .greaterOrEqual: return compare(a, b).map { .flag($0 != .orderedAscending) }
        case .isDefined: return .flag(a != nil)
        case .isUndefined: return .flag(a == nil)
        case .flagValue: return a
        case .currentDate:
            let c = calendar.dateComponents([.year, .month, .day], from: today)
            return .date(HelixDate(year: c.year!, month: c.month!, day: c.day!))
        case .dayOf, .monthOf, .yearOf:
            guard case .date(let d)? = a else { return nil }
            let c = d.components
            return .number(Double(op == .dayOf ? c.day : op == .monthOf ? c.month : c.year))
        default: return nil
        }
    }

    static func text(_ v: Value) -> String {
        if case .number(let n) = v, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return v.description
    }

    public static func parseNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Double(t) ?? Double(t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
    }

    /// Parses day-month-year text such as `1-6-1986` or `1/6/86`.
    public static func parseDate(_ s: String) -> HelixDate? {
        let parts = s.split(whereSeparator: { "-/. ".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3, (1...31).contains(parts[0]), (1...12).contains(parts[1]) else { return nil }
        let y = parts[2] < 100 ? parts[2] + (parts[2] < 30 ? 2000 : 1900) : parts[2]
        return HelixDate(year: y, month: parts[1], day: parts[0])
    }
}

extension HelixDate {
    /// Julian Day Number for a proleptic Gregorian date.
    public init(year: Int, month: Int, day: Int) {
        let a = (14 - month) / 12, y = year + 4800 - a, m = month + 12 * a - 3
        self.init(julianDay: day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045)
    }
}
