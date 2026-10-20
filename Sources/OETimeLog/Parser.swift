import Foundation

/// Parses the title grammar `client activity [+|-] free text [g|o|r]`.
/// If the first token is an activity code, the client defaults to `oe`
/// (so "sales follow-ups g" works).
struct ParsedEntry {
    var client: Client?
    var activity: Activity?
    var energy: String?
    var note: String
    var rating: Rating?
    var error: String?

    var isValid: Bool { client != nil && activity != nil }
}

enum Parser {
    static func parse(_ raw: String, codebook: Codebook) -> ParsedEntry {
        var tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var result = ParsedEntry(note: "")

        // Trailing rating token saves in one step.
        if tokens.count >= 2, let last = tokens.last, let r = Rating(token: last) {
            result.rating = r
            tokens.removeLast()
        }

        guard let first = tokens.first else {
            result.error = nil
            return result
        }

        if let a = codebook.activity(first), codebook.client(first) == nil {
            result.client = codebook.client("oe")
            result.activity = a
            tokens.removeFirst()
        } else if let c = codebook.client(first) {
            result.client = c
            tokens.removeFirst()
            if let second = tokens.first {
                if let a = codebook.activity(second) {
                    result.activity = a
                    tokens.removeFirst()
                } else {
                    result.error = "Unknown activity \"\(second)\""
                }
            } else {
                result.error = "Add an activity code"
            }
        } else {
            result.error = "Unknown client or activity \"\(first)\""
        }

        if let e = tokens.first, e == "+" || e == "-" {
            result.energy = e
            tokens.removeFirst()
        }
        result.note = tokens.joined(separator: " ")
        return result
    }

    /// Suggestions for the token currently being typed.
    static func suggestions(for raw: String, codebook: Codebook) -> [(code: String, name: String)] {
        let endsWithSpace = raw.hasSuffix(" ")
        let tokens = raw.split(separator: " ").map(String.init)
        let current = endsWithSpace ? "" : (tokens.last ?? "")
        let index = endsWithSpace ? tokens.count : max(0, tokens.count - 1)

        if index == 0 {
            let clients = codebook.clients.map { ($0.code, $0.name) }
            let acts = codebook.activities.map { ($0.code, $0.name) }
            return (clients + acts).filter { current.isEmpty || $0.0.hasPrefix(current.lowercased()) }
                .map { (code: $0.0, name: $0.1) }
        }
        if index == 1, codebook.client(tokens[0]) != nil {
            return codebook.activities.filter { current.isEmpty || $0.code.hasPrefix(current.lowercased()) }
                .map { (code: $0.code, name: $0.name) }
        }
        return []
    }

    /// Replaces the token being typed with `code` and adds a trailing space.
    static func complete(_ raw: String, with code: String) -> String {
        if raw.hasSuffix(" ") || raw.isEmpty { return raw + code + " " }
        var tokens = raw.split(separator: " ").map(String.init)
        tokens[tokens.count - 1] = code
        return tokens.joined(separator: " ") + " "
    }
}
