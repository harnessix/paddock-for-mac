import Foundation

/// A value of a text: a `String`, or another `UIText` that the app
/// localizes on its own before it fills it in.
public protocol UITextValue: Sendable {
    var uiTextValue: UIText.Value { get }
}

extension String: UITextValue {
    public var uiTextValue: UIText.Value { .string(self) }
}

/// A count: the value of a `%lld`. The catalog picks the plural form of
/// the language for it ("1 файл", "2 файла", "5 файлов").
extension Int: UITextValue {
    public var uiTextValue: UIText.Value { .count(self) }
}

extension Int64: UITextValue {
    public var uiTextValue: UIText.Value { .count(Int(clamping: self)) }
}

/// A user-visible text: a key of Localizable.xcstrings plus the values for
/// its `%@` placeholders. PaddockKit builds texts, the app localizes them.
/// The key is the English text, so `english` needs no catalog.
///
/// A count goes in a `%lld` and is an `Int`: the catalog has the plural
/// forms of each language for its key. A key has one count at most.
///
/// A value can be a text itself (`UIText("Used %@", Format.age(…))`): the
/// app localizes the inner text too, so no English word stays in a line
/// of another language.
///
/// `UIText.cli` is a line that paddock's CLI wrote. See `resolve`.
///
/// Two texts are equal when their English is built the same way: the key
/// and the English values. The inner texts and the fallback do not count.
public struct UIText: Hashable, Sendable, CustomStringConvertible {
    public enum Value: Sendable {
        case string(String)
        case text(UIText)
        case count(Int)
    }

    /// Where the words come from.
    indirect enum Source: Sendable {
        /// The launcher's own text: `key` is in the catalog.
        case own
        /// paddock's words (`args[0]`). `known` is the catalog text of a
        /// line that `CLIWords` knows. `fallback` is the launcher's own
        /// sentence for a line that it does not know.
        case cli(known: UIText?, fallback: UIText)
    }

    public let key: String
    /// The values in English.
    public let args: [String]
    /// The values that are texts themselves, by their place in `args`.
    let inner: [Int: UIText]
    /// The count of the text, for its plural form: the value of `%lld`.
    public let count: Int?
    let source: Source

    public init(_ key: String, _ args: any UITextValue...) {
        self.init(key: key, values: args.map(\.uiTextValue))
    }

    public init(key: String, args: [String]) {
        self.key = key
        self.args = args
        self.inner = [:]
        self.count = nil
        self.source = .own
    }

    public init(key: String, values: [Value]) {
        var english: [String] = []
        var inner: [Int: UIText] = [:]
        var count: Int?
        for (index, value) in values.enumerated() {
            switch value {
            case .string(let text):
                english.append(text)
            case .text(let text):
                english.append(text.english)
                inner[index] = text
            case .count(let number):
                english.append(String(number))
                count = number
            }
        }
        self.key = key
        self.args = english
        self.inner = inner
        self.count = count
        self.source = .own
    }

    private init(cli raw: String, known: UIText?, fallback: UIText) {
        self.key = "%@"
        self.args = [raw]
        self.inner = [:]
        self.count = nil
        self.source = .cli(known: known, fallback: fallback)
    }

    /// A line that paddock wrote, such as the reason of an error. The
    /// English interface shows it as it is. Another language shows the
    /// catalog text of a line that `CLIWords` knows, else `fallback`, with
    /// the line itself for the "Details" disclosure.
    public static func cli(_ raw: String, else fallback: UIText) -> UIText {
        UIText(cli: raw, known: CLIWords.known(raw), fallback: fallback)
    }

    /// True for a line of paddock.
    public var isCLI: Bool {
        if case .cli = source { return true }
        return false
    }

    /// The English text with the placeholders filled in.
    public var english: String { UIText.fill(key, args) }

    public var description: String { english }

    public static func == (a: UIText, b: UIText) -> Bool {
        a.key == b.key && a.args == b.args
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(args)
    }

    /// Replaces each `%@` and `%lld` of `format` with the next value of
    /// `args`, and each `%N$@` and `%N$lld` with value N (from 1). A
    /// translation uses `%N$@` when its language needs another order.
    public static func fill(_ format: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            guard character == "%" else {
                out.append(character)
                index = format.index(after: index)
                continue
            }
            var cursor = format.index(after: index)
            var digits = ""
            while cursor < format.endIndex, format[cursor].isASCII, format[cursor].isNumber {
                digits.append(format[cursor])
                cursor = format.index(after: cursor)
            }
            if digits.isEmpty, let end = UIText.specifier(format, at: cursor) {
                out += next < args.count ? args[next] : ""
                next += 1
                index = end
            } else if let place = Int(digits), cursor < format.endIndex, format[cursor] == "$",
                      let end = UIText.specifier(format, at: format.index(after: cursor)) {
                out += place >= 1 && place <= args.count ? args[place - 1] : ""
                index = end
            } else {
                out.append(character)
                index = format.index(after: index)
            }
        }
        return out
    }

    /// The number of values of `format` and the place (from 1) of its
    /// count, the `%lld`.
    public static func shape(of format: String) -> (places: Int, countPlace: Int?) {
        var places = 0
        var countPlace: Int?
        var index = format.startIndex
        while let percent = format[index...].firstIndex(of: "%") {
            var cursor = format.index(after: percent)
            var digits = ""
            while cursor < format.endIndex, format[cursor].isASCII, format[cursor].isNumber {
                digits.append(format[cursor])
                cursor = format.index(after: cursor)
            }
            if !digits.isEmpty, cursor < format.endIndex, format[cursor] == "$" { cursor = format.index(after: cursor) }
            guard let end = specifier(format, at: cursor) else {
                index = cursor
                continue
            }
            let place = Int(digits) ?? places + 1
            places = max(places, place)
            if format[cursor] == "l" { countPlace = place }
            index = end
        }
        return (places, countPlace)
    }

    /// The end of `@` or `lld` at `index`, else nil.
    private static func specifier(_ format: String, at index: String.Index) -> String.Index? {
        let rest = format[index...]
        if rest.hasPrefix("@") { return format.index(after: index) }
        if rest.hasPrefix("lld") { return format.index(index, offsetBy: 3) }
        return nil
    }
}

extension UIText {
    /// Texts in one line with `, ` between them, for a spoken label.
    public static func list(_ parts: [UIText]) -> UIText {
        UIText(key: Array(repeating: "%@", count: parts.count).joined(separator: ", "),
               values: parts.map { .text($0) })
    }

    /// A text that is one value as it is: a name, a path, a number.
    public static func verbatim(_ value: String) -> UIText {
        UIText(key: "%@", args: [value])
    }
}

extension TextCatalog {
    /// The format of `key`, in the plural form of `count` when it has one.
    func format(_ key: String, counted count: Int?) -> String? {
        if let count { return format(key, count: count) }
        return format(key)
    }
}

extension UIText: UITextValue {
    public var uiTextValue: UIText.Value { .text(self) }
}

/// The catalog of one interface language, as `UIText.resolve` needs it.
public protocol TextCatalog {
    /// True for the English interface: paddock's lines are English too.
    var isEnglish: Bool { get }
    /// The format of `key` in this language, or nil when the catalog has
    /// no text for it.
    func format(_ key: String) -> String?
    /// The format of a counted key in the plural form of `count`. The
    /// `%lld` may be filled in already; the other values stay `%@` or
    /// `%N$@`.
    func format(_ key: String, count: Int) -> String?
}

extension TextCatalog {
    public func format(_ key: String, count: Int) -> String? { format(key) }
}

/// The English interface: every key is its own text.
public struct EnglishCatalog: TextCatalog {
    public init() {}
    public var isEnglish: Bool { true }
    public func format(_ key: String) -> String? { key }
}

/// A catalog from a table, for another language and for the tests.
/// `plurals` has the forms of the counted keys ("one", "few", "many",
/// "other"), and `language` picks the form for a count.
public struct TableCatalog: TextCatalog {
    public var table: [String: String]
    public var plurals: [String: [String: String]]
    public var language: String
    public init(_ table: [String: String], plurals: [String: [String: String]] = [:], language: String = "zh-Hans") {
        self.table = table
        self.plurals = plurals
        self.language = language
    }
    public var isEnglish: Bool { false }
    public func format(_ key: String) -> String? { table[key] ?? plurals[key]?["other"] }
    public func format(_ key: String, count: Int) -> String? {
        guard let forms = plurals[key] else { return table[key] }
        return forms[PluralRule.form(of: count, language: language)] ?? forms["other"]
    }
}

/// The plural form of a count in a language, by the CLDR rules of the
/// languages of the interface. The bundle picks the form on the Mac;
/// this is the same rule for the tests and for `TableCatalog`.
public enum PluralRule {
    public static func form(of count: Int, language: String) -> String {
        let n = abs(count)
        switch language.split(separator: "-").first.map(String.init) ?? language {
        case "zh", "ja", "ko":
            return "other"
        case "fr":
            return n <= 1 ? "one" : "other"
        case "pt":
            // pt-BR: 0 and 1 are "one"; Portugal: only 1.
            return language == "pt-PT" ? (n == 1 ? "one" : "other") : (n <= 1 ? "one" : "other")
        case "ru", "uk":
            if n % 10 == 1 && n % 100 != 11 { return "one" }
            if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return "few" }
            return "many"
        default:
            return n == 1 ? "one" : "other"
        }
    }
}

/// A text in one language, and what it left out.
public struct ResolvedText: Equatable, Sendable {
    public var text: String
    /// The lines of paddock that this language has no text for. The
    /// window shows them under "Details", never in the sentence.
    public var details: String?
}

extension UIText {
    /// The text in the language of `catalog`.
    ///
    /// The one rule for paddock's own words: an interface that is not
    /// English never shows them raw. A line that `CLIWords` knows has a
    /// catalog text. Any other line gives way to the fallback sentence,
    /// and goes to `details`.
    public func resolve(_ catalog: TextCatalog) -> ResolvedText {
        var hidden: [String] = []
        let text = resolved(catalog, hidden: &hidden)
        return ResolvedText(text: text, details: hidden.isEmpty ? nil : hidden.joined(separator: "\n"))
    }

    private func resolved(_ catalog: TextCatalog, hidden: inout [String]) -> String {
        switch source {
        case .cli(let known, let fallback):
            let raw = args.first ?? ""
            if catalog.isEnglish { return raw }
            if let known, let text = known.plain(catalog) { return text }
            if !raw.isEmpty { hidden.append(raw) }
            return fallback.resolved(catalog, hidden: &hidden)
        case .own:
            let format = catalog.format(key, counted: count) ?? key
            var values = args
            for (index, text) in inner where index < values.count {
                values[index] = text.resolved(catalog, hidden: &hidden)
            }
            return UIText.fill(format, values)
        }
    }

    /// The text when the catalog has every part of it, else nil.
    private func plain(_ catalog: TextCatalog) -> String? {
        guard let format = catalog.format(key, counted: count) else { return nil }
        var values = args
        for (index, text) in inner where index < values.count {
            guard let value = text.plain(catalog) else { return nil }
            values[index] = value
        }
        return UIText.fill(format, values)
    }
}

/// Number and time formats of the copy rules: sizes in GB with one
/// decimal, times in minutes, no seconds above one minute.
public enum Format {
    static let gigabyte = 1_000_000_000.0

    /// `25.3 GB`. Decimal gigabytes, as Finder shows them.
    public static func gb(_ bytes: Int64) -> String {
        let value = Double(bytes) / gigabyte
        return String(format: "%.1f GB", value)
    }

    /// `25.3`, without the unit, for "6.2 of 13.1 GB".
    public static func gbNumber(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / gigabyte)
    }

    /// Whole gigabytes for memory: `16 GB`.
    public static func memoryGB(_ bytes: Int64) -> String {
        let gib = Double(bytes) / (1024 * 1024 * 1024)
        return "\(Int(gib.rounded())) GB"
    }

    /// Whole gigabytes without the unit: `16`.
    public static func memoryNumber(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / (1024 * 1024 * 1024)).rounded()))"
    }

    /// The age of a past moment: `just now`, `3 min ago`, `2 h ago`, `4 d ago`.
    public static func age(since date: Date, now: Date) -> UIText {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return UIText("just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return UIText("%@ min ago", "\(minutes)") }
        let hours = minutes / 60
        if hours < 48 { return UIText("%@ h ago", "\(hours)") }
        return UIText("%@ d ago", "\(hours / 24)")
    }

    /// The time left of a job: `less than a minute left`, `9 min left`.
    public static func timeLeft(seconds: Double) -> UIText {
        if seconds < 60 { return UIText("less than a minute left") }
        return UIText("%@ min left", "\(Int((seconds / 60).rounded(.up)))")
    }

    /// `~/Projects` for a path inside the home folder.
    public static func tildePath(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(prefix) { return "~/" + path.dropFirst(prefix.count) }
        return path
    }

    /// `12:04` in 24-hour time, for the Changes list.
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `3 Nov` for the base image build date.
    public static func dayMonth(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let month = months[max(0, min(11, (parts.month ?? 1) - 1))]
        return "\(parts.day ?? 1) \(month)"
    }
}
