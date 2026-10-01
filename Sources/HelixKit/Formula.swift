import Foundation

/// The text form of an abacus, used by the formula editor. Every tile tree prints to this
/// language and parses back to the same tree.
///
/// ```
/// if undefined([Artigo]) then [Título] else [Artigo] & " " & [Título]
/// [Precio Merca] ÷ 166.386
/// default(previous({Nome completo}) = {Nome completo}, false)
/// ```
/// - `[Field]` a field, `{Abacus}` another abacus (`]]` / `}}` escape a closing bracket)
/// - `"text"` (`""` for a quote), numbers, `true` / `false`, `#30-9-2026#` dates, `empty`
/// - infix, loosest first: `or` · `and` · `= ≠ < ≤ > ≥ contains starts with ends with` · `&` · `+ −` · `× ÷`
///   (`<> <= >= - * /` are accepted too)
/// - `if … then … else …`, and functions: `text number date day month year defined undefined
///   default flag total maximum minimum average previous not length upper lower trim left right mid
///   round abs int min max weekday makedate` plus `today`, `return`, `count`
public enum Formula {
    struct Spec { let op: Opcode; let name: String; let arity: Int }

    static let functions: [Spec] = [
        Spec(op: .textOf, name: "text", arity: 1), Spec(op: .numberOf, name: "number", arity: 1),
        Spec(op: .dateOf, name: "date", arity: 1), Spec(op: .dayOf, name: "day", arity: 1),
        Spec(op: .monthOf, name: "month", arity: 1), Spec(op: .yearOf, name: "year", arity: 1),
        Spec(op: .isDefined, name: "defined", arity: 1), Spec(op: .isUndefined, name: "undefined", arity: 1),
        Spec(op: .defaultValue, name: "default", arity: 2), Spec(op: .flagValue, name: "flag", arity: 1),
        Spec(op: .total, name: "total", arity: 1), Spec(op: .maximum, name: "maximum", arity: 1),
        Spec(op: .previous, name: "previous", arity: 1),
        Spec(op: .currentDate, name: "today", arity: 0), Spec(op: .returnCharacter, name: "return", arity: 0),
        Spec(op: .count, name: "count", arity: 0),
        Spec(op: .not, name: "not", arity: 1), Spec(op: .length, name: "length", arity: 1),
        Spec(op: .upper, name: "upper", arity: 1), Spec(op: .lower, name: "lower", arity: 1),
        Spec(op: .trim, name: "trim", arity: 1), Spec(op: .left, name: "left", arity: 2),
        Spec(op: .right, name: "right", arity: 2), Spec(op: .mid, name: "mid", arity: 3),
        Spec(op: .round, name: "round", arity: 2), Spec(op: .abs, name: "abs", arity: 1),
        Spec(op: .int, name: "int", arity: 1), Spec(op: .min, name: "min", arity: 2), Spec(op: .max, name: "max", arity: 2),
        Spec(op: .average, name: "average", arity: 1), Spec(op: .minimum, name: "minimum", arity: 1),
        Spec(op: .weekday, name: "weekday", arity: 1), Spec(op: .makeDate, name: "makedate", arity: 3),
    ]

    /// Infix operators with precedence (higher binds tighter).
    static let infix: [(op: Opcode, symbol: String, level: Int)] = [
        (.or, "or", 1), (.and, "and", 2),
        (.equal, "=", 3), (.notEqual, "≠", 3), (.lessOrEqual, "≤", 3), (.greaterOrEqual, "≥", 3),
        (.less, "<", 3), (.greater, ">", 3), (.contains, "contains", 3), (.startsWith, "starts with", 3),
        (.endsWith, "ends with", 3),
        (.followedBy, "&", 4), (.add, "+", 5), (.subtract, "−", 5), (.multiply, "×", 6), (.divide, "÷", 6),
    ]

    /// Names users can insert, for editor menus.
    public static var functionNames: [String] { functions.map { $0.arity == 0 ? $0.name : "\($0.name)()" } }
    public static var operatorSymbols: [String] { infix.map(\.symbol) }

    // MARK: Printing

    public static func print(_ tile: Tile?, name: (Int) -> String?) -> String {
        guard let tile else { return "" }
        return text(tile, name, top: true)
    }

    private static func text(_ t: Tile, _ name: (Int) -> String?, top: Bool = false) -> String {
        func esc(_ s: String, _ close: Character) -> String { s.replacingOccurrences(of: String(close), with: "\(close)\(close)") }
        switch t {
        case .field(let id): return "[\(esc(name(id) ?? "#\(id)", "]"))]"
        case .abacus(let id): return "{\(esc(name(id) ?? "#\(id)", "}"))}"
        case .empty, .constant(nil): return "empty"
        case .constant(let v?):
            switch v {
            case .text(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .flag(let b): return b ? "true" : "false"
            case .date(let d): return "#\(d.description)#"
            default: return "empty"
            }
        case .op(let op, let args, _):
            if op == .ifThenElse, args.count == 3 {
                let s = "if \(text(args[0], name)) then \(text(args[1], name)) else \(text(args[2], name))"
                return top ? s : "(\(s))"
            }
            if let i = infix.first(where: { $0.op == op }), args.count == 2 {
                func side(_ a: Tile) -> String {
                    if case .op(let o, let aa, _) = a, aa.count == 2, infix.contains(where: { $0.op == o }) {
                        return "(\(text(a, name, top: true)))"
                    }
                    return text(a, name)
                }
                let s = "\(side(args[0])) \(i.symbol) \(side(args[1]))"
                return s
            }
            let fname: String
            if let f = functions.first(where: { $0.op == op }) {
                if f.arity == 0 && args.isEmpty { return f.name }
                fname = f.name
            } else if case .unknown(let c) = op {
                fname = "op_" + String(c, radix: 16)
            } else {
                fname = op.description
            }
            return "\(fname)(\(args.map { text($0, name, top: true) }.joined(separator: ", ")))"
        }
    }

    // MARK: Parsing

    public struct ParseError: Error, LocalizedError, Equatable {
        public let message: String
        public let offset: Int
        public var errorDescription: String? { message }
        public init(message: String, offset: Int) { (self.message, self.offset) = (message, offset) }
    }

    /// Parses formula text. `field` / `abacus` resolve names to object ids; `newTileID`
    /// supplies ids for operator tiles (they key summary caches, so must be unique).
    public static func parse(_ source: String, field: @escaping (String) -> Int?, abacus: @escaping (String) -> Int?,
                             newTileID: @escaping () -> Int) throws -> Tile {
        var p = Parser(chars: Array(source), field: field, abacus: abacus, newTileID: newTileID)
        let t = try p.expression()
        p.skipSpace()
        guard p.i == p.chars.count else { throw p.error("Unexpected “\(String(p.chars[p.i...]).prefix(12))”") }
        return t
    }

    struct Parser {
        let chars: [Character]
        var i = 0
        let field: (String) -> Int?
        let abacus: (String) -> Int?
        let newTileID: () -> Int

        init(chars: [Character], field: @escaping (String) -> Int?, abacus: @escaping (String) -> Int?, newTileID: @escaping () -> Int) {
            (self.chars, self.field, self.abacus, self.newTileID) = (chars, field, abacus, newTileID)
        }

        func error(_ m: String) -> ParseError { ParseError(message: m, offset: i) }

        mutating func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        /// Matches a word or symbol (case-insensitive for words, which must end at a boundary).
        mutating func accept(_ token: String) -> Bool {
            skipSpace()
            let t = Array(token)
            guard i + t.count <= chars.count,
                  String(chars[i..<i + t.count]).lowercased() == token.lowercased() else { return false }
            if t.last!.isLetter, i + t.count < chars.count, chars[i + t.count].isLetter || chars[i + t.count] == "_" { return false }
            i += t.count
            return true
        }

        mutating func expect(_ token: String) throws {
            guard accept(token) else { throw error("Expected “\(token)”") }
        }

        mutating func op(_ o: Opcode, _ args: [Tile]) -> Tile { .op(o, args, tileID: newTileID()) }

        mutating func expression() throws -> Tile {
            if accept("if") {
                let c = try expression()
                try expect("then")
                let a = try expression()
                try expect("else")
                let b = try expression()
                return op(.ifThenElse, [c, a, b])
            }
            return try binary(1)
        }

        static let aliases: [(String, Opcode)] = [("<>", .notEqual), ("<=", .lessOrEqual), (">=", .greaterOrEqual),
                                                    ("-", .subtract), ("*", .multiply), ("/", .divide)]

        mutating func binaryOp(level: Int) -> Opcode? {
            let save = i
            for (sym, o) in Self.aliases where Formula.infix.first(where: { $0.op == o })!.level == level {
                if accept(sym) { return o }
            }
            for e in Formula.infix where e.level == level {
                if accept(e.symbol) { return e.op }
            }
            i = save
            return nil
        }

        mutating func binary(_ level: Int) throws -> Tile {
            guard level <= 6 else { return try primary() }
            var lhs = try binary(level + 1)
            while let o = binaryOp(level: level) {
                let rhs = try binary(level + 1)
                lhs = op(o, [lhs, rhs])
            }
            return lhs
        }

        mutating func bracketed(_ close: Character) throws -> String {
            var s = ""
            while i < chars.count {
                if chars[i] == close {
                    if i + 1 < chars.count, chars[i + 1] == close { s.append(close); i += 2; continue }
                    i += 1
                    return s
                }
                s.append(chars[i]); i += 1
            }
            throw error("Missing “\(close)”")
        }

        mutating func primary() throws -> Tile {
            skipSpace()
            guard i < chars.count else { throw error("Formula ends too early") }
            let c = chars[i]
            switch c {
            case "(":
                i += 1
                let t = try expression()
                try expect(")")
                return t
            case "[":
                i += 1
                let start = i
                let n = try bracketed("]")
                guard let id = field(n) else { throw ParseError(message: "No field named “\(n)”", offset: start) }
                return .field(objectID: id)
            case "{":
                i += 1
                let start = i
                let n = try bracketed("}")
                guard let id = abacus(n) else { throw ParseError(message: "No abacus named “\(n)”", offset: start) }
                return .abacus(objectID: id)
            case "\"":
                i += 1
                var s = ""
                while true {
                    guard i < chars.count else { throw error("Missing closing quote") }
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" { s.append("\""); i += 2; continue }
                        i += 1
                        return .constant(.text(s))
                    }
                    s.append(chars[i]); i += 1
                }
            case "#":
                i += 1
                let start = i
                let s = try bracketed("#")
                guard let d = AbacusEvaluator.parseDate(s) else { throw ParseError(message: "Not a date: “\(s)”", offset: start) }
                return .constant(.date(d))
            case "□":
                i += 1
                return .empty
            default:
                let negative = (c == "-" || c == "−") && i + 1 < chars.count && chars[i + 1].isNumber
                if c.isNumber || negative || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    var s = ""
                    if negative { s = "-"; i += 1 }
                    while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
                    guard let n = Double(s) else { throw error("Not a number: \(s)") }
                    return .constant(.number(n))
                }
                guard c.isLetter else { throw error("Unexpected “\(c)”") }
                var word = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { word.append(chars[i]); i += 1 }
                switch word.lowercased() {
                case "true": return .constant(.flag(true))
                case "false": return .constant(.flag(false))
                case "empty": return .empty
                default: break
                }
                let opcode: Opcode
                let arity: Int?
                if let f = Formula.functions.first(where: { $0.name == word.lowercased() }) {
                    (opcode, arity) = (f.op, f.arity)
                } else if word.lowercased().hasPrefix("op_"), let code = UInt16(word.dropFirst(3), radix: 16) {
                    (opcode, arity) = (Opcode(code: code), nil)
                } else {
                    throw ParseError(message: "Unknown word “\(word)”", offset: i - word.count)
                }
                var args: [Tile] = []
                if accept("(") {
                    if !accept(")") {
                        repeat { args.append(try expression()) } while accept(",")
                        try expect(")")
                    }
                }
                if let arity, args.count != arity {
                    throw error("“\(word)” takes \(arity) value\(arity == 1 ? "" : "s")")
                }
                return op(opcode, args)
            }
        }
    }
}

extension Tile {
    /// The tree with operator tile ids zeroed, for comparing structure.
    public var structure: Tile {
        if case .op(let o, let a, _) = self { return .op(o, a.map(\.structure), tileID: 0) }
        return self
    }

    /// Field and abacus object ids used anywhere in the tree.
    public var references: Set<Int> {
        switch self {
        case .field(let id), .abacus(let id): [id]
        case .op(_, let a, _): a.reduce(into: Set<Int>()) { $0.formUnion($1.references) }
        default: []
        }
    }
}
