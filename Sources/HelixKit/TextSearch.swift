import Foundation

/// Forgiving text search: case, accents, punctuation and word order don't matter, so
/// "Chao Rego, Xosé", "xose chao rego" and "Xosé Chao Rego" all find the same records.
public enum TextSearch {
    /// Lower-case, accent-free words of a string.
    public static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Normalised text to search in (words joined by spaces).
    public static func haystack(_ parts: [String]) -> String {
        " " + parts.flatMap(words).joined(separator: " ") + " "
    }

    /// True if every query word occurs in the haystack (as the start of a word).
    public static func matches(_ haystack: String, query: [String]) -> Bool {
        query.allSatisfy { haystack.contains(" " + $0) }
    }

    /// The text of a record's fields for searching.
    public static func haystack(for record: Record, in relation: Relation) -> String {
        haystack(relation.fields.compactMap { record[$0]?.description })
    }

    /// Whether two values are "the same" for drilling down (text compared loosely).
    public static func same(_ a: Value?, _ b: Value?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (nil, _), (_, nil): false
        case let (.number(x)?, .number(y)?): x == y
        case let (.date(x)?, .date(y)?): x == y
        case let (.flag(x)?, .flag(y)?): x == y
        default: words(a!.description) == words(b!.description)
        }
    }
}

/// Helix-style "find by form": criteria typed into a form's fields.
///
/// - `Vigo` — text containing those words (any order, accents ignored); numbers/dates: equal
/// - `= Vigo` exactly; `≠ Vigo` / `<> Vigo` not equal
/// - `< 1990`, `≤ 1990` / `<= 1990`, `> 1990`, `≥ 1990` / `>= 1990` — numbers, dates (d-m-yyyy) or text
/// - `=` alone — the field is empty; `≠` alone — the field has a value
public enum FindCriteria {
    public static func matches(_ value: Value?, _ criterion: String, type: FieldType) -> Bool {
        let c = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return true }
        let ops = ["<>", "<=", ">=", "≠", "≤", "≥", "=", "<", ">"]
        let op = ops.first { c.hasPrefix($0) }
        let rest = op.map { String(c.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? c
        let empty: Bool = { if case .text(let s)? = value { s.isEmpty } else { value == nil } }()
        if rest.isEmpty, let op {
            return (op == "=") ? empty : (op == "≠" || op == "<>") ? !empty : true
        }
        guard op != nil else {
            switch type {
            case .number, .date: return compare(value, rest, type) == .orderedSame
            case .flag:
                let yes = ["yes", "si", "sí", "true", "1", "x"].contains(rest.lowercased())
                if case .flag(let b)? = value { return b == yes }
                return !yes
            default:
                let hay = TextSearch.haystack([value?.description ?? ""])
                return TextSearch.matches(hay, query: TextSearch.words(rest))
            }
        }
        guard let r = compare(value, rest, type) else { return op == "≠" || op == "<>" }
        switch op! {
        case "=": return r == .orderedSame
        case "≠", "<>": return r != .orderedSame
        case "<": return r == .orderedAscending
        case "≤", "<=": return r != .orderedDescending
        case ">": return r == .orderedDescending
        default: return r != .orderedAscending
        }
    }

    private static func compare(_ value: Value?, _ s: String, _ type: FieldType) -> ComparisonResult? {
        guard let value else { return nil }
        switch value {
        case .number(let n):
            guard let x = AbacusEvaluator.parseNumber(s) else { return nil }
            return n == x ? .orderedSame : n < x ? .orderedAscending : .orderedDescending
        case .date(let d):
            guard let x = AbacusEvaluator.parseDate(s) else { return nil }
            return d == x ? .orderedSame : d < x ? .orderedAscending : .orderedDescending
        default:
            let t = value.description
            if let a = AbacusEvaluator.parseNumber(t), let b = AbacusEvaluator.parseNumber(s), type != .text || Double(t) != nil {
                return a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            }
            return TextSearch.words(t).joined(separator: " ").compare(TextSearch.words(s).joined(separator: " "))
        }
    }
}
