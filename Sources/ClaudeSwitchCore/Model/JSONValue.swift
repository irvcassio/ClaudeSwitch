import Foundation

/// An order-preserving JSON tree.
///
/// `~/.claude/settings.json` is a file the user hand-edits. Round-tripping it through
/// `JSONSerialization` would silently reorder every top-level key and rewrite every number,
/// so a one-line toggle would show up as a whole-file diff. This keeps object key order and
/// keeps numbers as their original text.
public indirect enum JSONValue {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])
}

// MARK: - Object accessors

extension JSONValue {
    public var objectEntries: [(key: String, value: JSONValue)]? {
        if case .object(let entries) = self { return entries }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        get { objectEntries?.first { $0.key == key }?.value }
        set {
            guard case .object(var entries) = self else { return }
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key: key, value: newValue))
            }
            self = .object(entries)
        }
    }
}

// MARK: - Parsing

extension JSONValue {
    public enum ParseError: LocalizedError {
        case unexpected(Character, at: Int)
        case truncated
        case invalidNumber(String)

        public var errorDescription: String? {
            switch self {
            case .unexpected(let c, let i): "Unexpected character '\(c)' at offset \(i)."
            case .truncated: "The file ended in the middle of a JSON value."
            case .invalidNumber(let s): "'\(s)' is not a valid JSON number."
            }
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(Array(text))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if !parser.isAtEnd { throw ParseError.unexpected(parser.peek!, at: parser.index) }
        return value
    }

    private struct Parser {
        private let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var isAtEnd: Bool { index >= chars.count }
        var peek: Character? { isAtEnd ? nil : chars[index] }

        mutating func skipWhitespace() {
            while let c = peek, c == " " || c == "\n" || c == "\r" || c == "\t" { index += 1 }
        }

        private mutating func expect(_ expected: Character) throws {
            guard let c = peek else { throw ParseError.truncated }
            guard c == expected else { throw ParseError.unexpected(c, at: index) }
            index += 1
        }

        private mutating func consume(literal: String) throws {
            for c in literal { try expect(c) }
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard let c = peek else { throw ParseError.truncated }
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try consume(literal: "true"); return .bool(true)
            case "f": try consume(literal: "false"); return .bool(false)
            case "n": try consume(literal: "null"); return .null
            default: return try parseNumber()
            }
        }

        private mutating func parseObject() throws -> JSONValue {
            try expect("{")
            var entries: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if peek == "}" { index += 1; return .object(entries) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                entries.append((key: key, value: try parseValue()))
                skipWhitespace()
                guard let c = peek else { throw ParseError.truncated }
                if c == "," { index += 1; continue }
                if c == "}" { index += 1; return .object(entries) }
                throw ParseError.unexpected(c, at: index)
            }
        }

        private mutating func parseArray() throws -> JSONValue {
            try expect("[")
            var items: [JSONValue] = []
            skipWhitespace()
            if peek == "]" { index += 1; return .array(items) }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                guard let c = peek else { throw ParseError.truncated }
                if c == "," { index += 1; continue }
                if c == "]" { index += 1; return .array(items) }
                throw ParseError.unexpected(c, at: index)
            }
        }

        private mutating func parseString() throws -> String {
            try expect("\"")
            var out = ""
            while true {
                guard let c = peek else { throw ParseError.truncated }
                index += 1
                if c == "\"" { return out }
                guard c == "\\" else { out.append(c); continue }
                guard let escape = peek else { throw ParseError.truncated }
                index += 1
                switch escape {
                case "\"", "\\", "/": out.append(escape)
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    let hex = String(chars[index ..< min(index + 4, chars.count)])
                    guard hex.count == 4, let scalar = UInt32(hex, radix: 16) else {
                        throw ParseError.unexpected(escape, at: index)
                    }
                    index += 4
                    // A high surrogate is only meaningful paired with the low one that follows.
                    if (0xD800 ... 0xDBFF).contains(scalar), index + 6 <= chars.count,
                       chars[index] == "\\", chars[index + 1] == "u",
                       let low = UInt32(String(chars[index + 2 ..< index + 6]), radix: 16),
                       (0xDC00 ... 0xDFFF).contains(low) {
                        index += 6
                        let combined = 0x10000 + (scalar - 0xD800) * 0x400 + (low - 0xDC00)
                        out.append(Character(UnicodeScalar(combined)!))
                    } else if let unicode = UnicodeScalar(scalar) {
                        out.append(Character(unicode))
                    }
                default: throw ParseError.unexpected(escape, at: index)
                }
            }
        }

        private mutating func parseNumber() throws -> JSONValue {
            let start = index
            while let c = peek, "0123456789+-.eE".contains(c) { index += 1 }
            let text = String(chars[start ..< index])
            guard !text.isEmpty, Double(text) != nil else { throw ParseError.invalidNumber(text) }
            return .number(text)
        }
    }
}

// MARK: - Serializing

extension JSONValue {
    /// Pretty-prints with two-space indent — the shape Claude Code itself writes.
    public func serialized(indent level: Int = 0) -> String {
        let pad = String(repeating: "  ", count: level)
        let padInner = String(repeating: "  ", count: level + 1)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return Self.quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { padInner + $0.serialized(indent: level + 1) }
            return "[\n" + body.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let entries):
            if entries.isEmpty { return "{}" }
            let body = entries.map { padInner + Self.quote($0.key) + ": " + $0.value.serialized(indent: level + 1) }
            return "{\n" + body.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }
}
