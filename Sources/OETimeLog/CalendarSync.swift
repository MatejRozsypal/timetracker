import Foundation

/// Pushes queued entries to the app's own "OE Time log" calendar.
@MainActor
final class CalendarSync: ObservableObject {
    @Published private(set) var syncing = false
    @Published var lastError: String?

    private let store: Store
    private let auth: GoogleAuth
    private let api = "https://www.googleapis.com/calendar/v3"

    init(store: Store, auth: GoogleAuth) {
        self.store = store
        self.auth = auth
    }

    var pending: Int { store.unsynced.count }

    func flush() async {
        guard auth.signedIn, !syncing, !store.unsynced.isEmpty else { return }
        syncing = true
        defer { syncing = false }
        do {
            let calId = try await calendarId()
            for entry in store.unsynced {
                try await insert(entry, calendarId: calId)
                store.markSynced(entry.id)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Calendar

    private func calendarId() async throws -> String {
        if let id = store.state.calendarId { return id }
        // calendar.app.created can list the calendars this app made, so a
        // reinstall finds the existing calendar instead of creating a second one.
        let list = try await request("GET", "/users/me/calendarList")
        let items = list["items"] as? [[String: Any]] ?? []
        if let existing = items.first(where: { ($0["summary"] as? String) == store.config.calendarName }),
           let id = existing["id"] as? String {
            store.setCalendarId(id)
            return id
        }
        let created = try await request("POST", "/calendars", body: [
            "summary": store.config.calendarName,
            "description": "Time study log written by OE Time Log. Title grammar: client activity [+|-] note. Colour = focus (Basil green, Tangerine orange, Tomato red).",
            "timeZone": TimeZone.current.identifier,
        ])
        guard let id = created["id"] as? String else { throw SyncError.http(0, "calendar create returned no id") }
        store.setCalendarId(id)
        return id
    }

    private func insert(_ e: LogEntry, calendarId: String) async throws {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone.current
        let tz = TimeZone.current.identifier
        var priv: [String: String] = [
            "app": "oe-timelog", "v": "1",
            "client": e.client, "activity": e.activity, "bucket": e.bucket,
            "rating": e.rating?.rawValue ?? "unrated",
            "trigger": e.trigger.rawValue, "format": "solo",
        ]
        if let en = e.energy { priv["energy"] = en }
        var body: [String: Any] = [
            "id": e.id,
            "summary": e.title,
            "start": ["dateTime": iso.string(from: e.start), "timeZone": tz],
            "end": ["dateTime": iso.string(from: e.end), "timeZone": tz],
            "transparency": "transparent",
            "reminders": ["useDefault": false],
            "extendedProperties": ["private": priv],
        ]
        if let r = e.rating { body["colorId"] = r.colorId }
        let path = "/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId)/events"
        do {
            _ = try await request("POST", path, body: body)
        } catch SyncError.http(409, _) {
            // Same id already exists: an earlier attempt succeeded.
        } catch SyncError.http(404, _) {
            // The calendar was deleted by hand. Forget it and retry next flush.
            store.setCalendarId(nil)
            throw SyncError.http(404, "log calendar not found, it will be recreated")
        }
    }

    // MARK: HTTP

    enum SyncError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "Calendar API \(code): \(msg)"
            }
        }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await auth.accessToken()
        var req = URLRequest(url: URL(string: api + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw SyncError.http(code, msg)
        }
        return json
    }
}
