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
