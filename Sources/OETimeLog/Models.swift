import Foundation

enum Rating: String, Codable, CaseIterable {
    case green, orange, red

    /// Google Calendar EventColor ids: Basil, Tangerine, Tomato.
    var colorId: String {
        switch self {
        case .green: return "10"
        case .orange: return "6"
        case .red: return "11"
        }
    }

    var anchor: String {
        switch self {
        case .green: return "Single-tasking, did what I sat down to do"
        case .orange: return "Done, but with switching or slower than it should be"
        case .red: return "Distracted or reactive, the block produced little"
        }
    }

    var points: Double {
        switch self {
        case .green: return 2
        case .orange: return 1
        case .red: return 0
        }
    }

    init?(token: String) {
        switch token.lowercased() {
        case "g": self = .green
        case "o": self = .orange
        case "r": self = .red
        default: return nil
        }
    }
}

struct Client: Codable, Hashable {
    let code: String
    let name: String
}

struct Activity: Codable, Hashable {
    let code: String
    let name: String
    let bucket: String
    let tier: String
}

struct Codebook: Codable {
    var clients: [Client]
    var activities: [Activity]

    /// Special codes that exist for every codebook. `off` never leaves the Mac,
    /// `unknown` keeps the calendar contiguous when a gap cannot be recalled.
    static let off = Activity(code: "off", name: "Not work (break, personal)", bucket: "off", tier: "")
    static let unknown = Activity(code: "unknown", name: "Unknown", bucket: "unknown", tier: "")

    func client(_ code: String) -> Client? { clients.first { $0.code == code.lowercased() } }

    func activity(_ code: String) -> Activity? {
        let c = code.lowercased()
        if c == Codebook.off.code { return Codebook.off }
        if c == Codebook.unknown.code { return Codebook.unknown }
        return activities.first { $0.code == c }
    }

    static func load() -> Codebook {
        let candidates = [
            Paths.support.appendingPathComponent("codebook.json"),
            Bundle.main.url(forResource: "codebook", withExtension: "json"),
        ].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let book = try? JSONDecoder().decode(Codebook.self, from: data) {
                return book
            }
        }
        return Codebook(clients: [Client(code: "oe", name: "One Eighty")], activities: [])
    }
}

enum Trigger: String, Codable {
    case hotkey, returned, nudge, sweep, notification
}

struct LogEntry: Codable, Identifiable {
    /// Lowercase hex UUID without dashes: valid base32hex, so it doubles as the
    /// Google Calendar event id and makes retries idempotent.
    let id: String
    let start: Date
    let end: Date
    let client: String
    let activity: String
    let bucket: String
    let energy: String?      // "+", "-" or nil
    let note: String
    let rating: Rating?
    let trigger: Trigger

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isOff: Bool { activity == Codebook.off.code }

    var title: String {
        if activity == Codebook.unknown.code { return note.isEmpty ? "unknown" : "unknown \(note)" }
        var parts = [client, activity]
        if let energy { parts.append(energy) }
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " ")
    }

    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// A stretch when the user was away from the Mac (locked, asleep or idle).
struct AwaySegment: Codable {
    let start: Date
    let end: Date
}

/// An uncovered stretch of the day, shown in the sweep.
struct Gap: Identifiable, Hashable {
    let start: Date
    let end: Date
    let away: Bool
    let current: Bool
    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OETimeLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func range(_ a: Date, _ b: Date) -> String {
        "\(time.string(from: a)) to \(time.string(from: b))"
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = max(0, Int((t / 60).rounded()))
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}
