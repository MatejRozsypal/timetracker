import Foundation

/// Persistent state that survives restarts.
struct AppState: Codable {
    var dayStart: Date?
    var lastBoundary: Date?
    var calendarId: String?
    var away: [AwaySegment] = []
    var sweepShownOn: String?
    var syncedIds: [String] = []
}

/// Local source of truth. Every entry is appended to entries.jsonl first and
/// pushed to Google Calendar afterwards, so nothing is lost offline.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var state = AppState()
    @Published var codebook = Codebook.load()
    @Published var config = Config.load()

    private let entriesURL = Paths.support.appendingPathComponent("entries.jsonl")
    private let stateURL = Paths.support.appendingPathComponent("state.json")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        if let data = try? Data(contentsOf: stateURL), let s = try? decoder.decode(AppState.self, from: data) {
            state = s
        }
        if let text = try? String(contentsOf: entriesURL, encoding: .utf8) {
            entries = text.split(separator: "\n").compactMap { try? decoder.decode(LogEntry.self, from: Data($0.utf8)) }
        }
    }

    // MARK: Day boundaries

    var today: [LogEntry] {
        let start = Calendar.current.startOfDay(for: Date())
        return entries.filter { $0.end > start }.sorted { $0.start < $1.start }
    }

    var recentCodes: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries.reversed() where !e.isOff && e.activity != Codebook.unknown.code {
            let code = e.activity == e.client ? e.activity : "\(e.client) \(e.activity)"
            if seen.insert(code).inserted { out.append(code) }
            if out.count == 8 { break }
        }
        return out
    }

    /// Where the next block starts. Never earlier than today's day start.
    var blockStart: Date {
        ensureDay()
        return state.lastBoundary ?? state.dayStart ?? Date()
    }

    /// Starts a new day if the stored boundary belongs to an earlier day.
    func ensureDay(now: Date = Date()) {
        let cal = Calendar.current
        if let ds = state.dayStart, cal.isDate(ds, inSameDayAs: now) { return }
        state.dayStart = now
        state.lastBoundary = now
        state.away = []
        save()
    }

    func setBoundary(_ d: Date) {
        state.lastBoundary = d
        save()
    }

    func addAway(_ seg: AwaySegment) {
        guard seg.end.timeIntervalSince(seg.start) >= 60 else { return }
        state.away.append(seg)
        save()
    }

    func setCalendarId(_ id: String?) {
        state.calendarId = id
        save()
    }

    func markSweepShown() {
        state.sweepShownOn = Self.dayKey(Date())
        save()
    }

    var sweepShownToday: Bool { state.sweepShownOn == Self.dayKey(Date()) }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: Entries

    @discardableResult
    func add(start: Date, end: Date, parsed: ParsedEntry, rating: Rating?, trigger: Trigger) -> LogEntry? {
        guard let client = parsed.client, let activity = parsed.activity, end > start else { return nil }
        let entry = LogEntry(
            id: LogEntry.newId(), start: start, end: end,
            client: client.code, activity: activity.code, bucket: activity.bucket,
            energy: parsed.energy, note: parsed.note, rating: rating, trigger: trigger
        )
        entries.append(entry)
        if let data = try? encoder.encode(entry) {
            let line = data + Data("\n".utf8)
            if let h = try? FileHandle(forWritingTo: entriesURL) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: entriesURL)
            }
        }
        if entry.isOff { markSynced(entry.id) }
        return entry
    }

    var unsynced: [LogEntry] {
        let done = Set(state.syncedIds)
        return entries.filter { !done.contains($0.id) && !$0.isOff }
    }

    func markSynced(_ id: String) {
        state.syncedIds.append(id)
        // Keep the list bounded: anything older than the last 2,000 ids is long synced.
        if state.syncedIds.count > 2000 { state.syncedIds.removeFirst(state.syncedIds.count - 2000) }
        save()
    }

    // MARK: Stats

    /// Uncovered stretches of today, from day start to now, ignoring anything under 5 minutes.
    func gaps(now: Date = Date()) -> [Gap] {
        ensureDay(now: now)
        guard let dayStart = state.dayStart else { return [] }
        var cursor = dayStart
        var out: [Gap] = []
        let covered = today.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        func emit(_ a: Date, _ b: Date) {
            guard b.timeIntervalSince(a) >= 300 else { return }
            out.append(Gap(start: a, end: b, away: isMostlyAway(a, b), current: b >= now.addingTimeInterval(-1)))
        }
        for (s, e) in covered {
            if s > cursor { emit(cursor, min(s, now)) }
            cursor = max(cursor, e)
        }
        if now > cursor { emit(cursor, now) }
        return out
    }

    private func isMostlyAway(_ a: Date, _ b: Date) -> Bool {
        let total = b.timeIntervalSince(a)
        let overlap = state.away.reduce(0.0) { acc, seg in
            let s = max(seg.start, a), e = min(seg.end, b)
            return acc + max(0, e.timeIntervalSince(s))
        }
        return total > 0 && overlap / total > 0.5
    }

    struct DayStats {
        var logged: TimeInterval = 0
        var unlogged: TimeInterval = 0
        var green: TimeInterval = 0
        var orange: TimeInterval = 0
        var red: TimeInterval = 0
        var unrated: TimeInterval = 0
        var focusScore: Int? = nil
    }

    func stats(now: Date = Date()) -> DayStats {
        var s = DayStats()
        for e in today where !e.isOff {
            s.logged += e.duration
            switch e.rating {
            case .green: s.green += e.duration
            case .orange: s.orange += e.duration
            case .red: s.red += e.duration
            case nil: s.unrated += e.duration
            }
        }
        s.unlogged = gaps(now: now).filter { !$0.away && !$0.current }.reduce(0) { $0 + $1.duration }
        let rated = s.green + s.orange + s.red
        if rated > 0 { s.focusScore = Int(((2 * s.green + s.orange) / (2 * rated) * 100).rounded()) }
        return s
    }

    // MARK: Persistence

    func reloadConfig() {
        config = Config.load()
        codebook = Codebook.load()
    }

    private func save() {
        if let data = try? encoder.encode(state) { try? data.write(to: stateURL) }
    }
}
