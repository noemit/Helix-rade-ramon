import Foundation

public enum FieldType: UInt8, CaseIterable, CustomStringConvertible {
    case text = 0
    case number = 1
    case date = 2
    case flag = 3
    case picture = 4
    case unknown = 0xFF

    public init(code: UInt8) { self = FieldType(rawValue: code) ?? .unknown }

    public var description: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .date: "Date"
        case .flag: "Flag"
        case .picture: "Picture"
        case .unknown: "Unknown"
        }
    }
}

/// Helix dates are stored as a Julian Day Number plus seconds since midnight.
public struct HelixDate: Hashable, Comparable, CustomStringConvertible {
    public let julianDay: Int
    public let seconds: Int

    public init(julianDay: Int, seconds: Int = 0) {
        self.julianDay = julianDay
        self.seconds = seconds
    }

    /// Proleptic Gregorian (year, month, day) for the Julian Day Number.
    public var components: (year: Int, month: Int, day: Int) {
        let a = julianDay + 32044
        let b = (4 * a + 3) / 146097
        let c = a - 146097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        return (100 * b + d - 4800 + m / 10, m + 3 - 12 * (m / 10), e - (153 * m + 2) / 5 + 1)
    }

    public var date: Date? {
        let c = components
        var dc = DateComponents(year: c.year, month: c.month, day: c.day)
        dc.second = seconds
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: dc)
    }

    public var description: String {
        let c = components
        var s = String(format: "%d-%d-%04d", c.day, c.month, c.year)
        if seconds > 0 {
            s += String(format: " %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return s
    }

    public static func < (l: HelixDate, r: HelixDate) -> Bool {
        (l.julianDay, l.seconds) < (r.julianDay, r.seconds)
    }
}

extension HelixDate: Codable {}

/// JSON form used by the history log: `{"t": "text"}`, `{"n": 1.5}`, `{"d": [jd, secs]}`,
/// `{"f": true}`, `{"p": base64}`, `{"r": base64}`.
extension Value: Codable {
    private enum Key: String, CodingKey { case t, n, d, f, p, r }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let s = try c.decodeIfPresent(String.self, forKey: .t) { self = .text(s) }
        else if let n = try c.decodeIfPresent(Double.self, forKey: .n) { self = .number(n) }
        else if let d = try c.decodeIfPresent([Int].self, forKey: .d), d.count == 2 { self = .date(HelixDate(julianDay: d[0], seconds: d[1])) }
        else if let f = try c.decodeIfPresent(Bool.self, forKey: .f) { self = .flag(f) }
        else if let p = try c.decodeIfPresent(Data.self, forKey: .p) { self = .picture(p) }
        else { self = .raw(try c.decode(Data.self, forKey: .r)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .text(let s): try c.encode(s, forKey: .t)
        case .number(let n): try c.encode(n, forKey: .n)
        case .date(let d): try c.encode([d.julianDay, d.seconds], forKey: .d)
        case .flag(let f): try c.encode(f, forKey: .f)
        case .picture(let p): try c.encode(p, forKey: .p)
        case .raw(let r): try c.encode(r, forKey: .r)
        }
    }
}

public enum Value: Hashable, CustomStringConvertible {
    case text(String)
    case number(Double)
    case date(HelixDate)
    case flag(Bool)
    case picture(Data)
    case raw(Data)

    public var description: String {
        switch self {
        case .text(let s): s
        case .number(let n): Value.numberFormatter.string(from: NSNumber(value: n)) ?? String(n)
        case .date(let d): d.description
        case .flag(let b): b ? "Yes" : "No"
        case .picture(let d): "<picture \(d.count) bytes>"
        case .raw(let d): "<\(d.count) bytes>"
        }
    }

    public var text: String? { if case .text(let s) = self { s } else { nil } }

    static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 6
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Total ordering used for sorting mixed columns: numbers/dates before text.
    public static func sortLess(_ a: Value?, _ b: Value?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (.number(x)?, .number(y)?): return x < y
        case let (.date(x)?, .date(y)?): return x < y
        case let (.flag(x)?, .flag(y)?): return !x && y
        default:
            return a!.description.localizedStandardCompare(b!.description) == .orderedAscending
        }
    }
}
