import Foundation

/// User settings, read from ~/Library/Application Support/OETimeLog/config.json.
/// Missing keys fall back to the defaults below. The Google client id and secret
/// live only here, never in the repo.
struct Config: Codable {
    var googleClientId: String = ""
    var googleClientSecret: String = ""
    var calendarName: String = "OE Time log"
    var workStart: String = "08:00"
    var workEnd: String = "20:00"
    /// Calendar weekday numbers, 1 = Sunday ... 7 = Saturday.
    var workDays: [Int] = [2, 3, 4, 5, 6]
    var awayMinutes: Double = 10
    var nudgeMinutes: Double = 75
    var sweepTime: String = "18:30"
    /// Modifier names: cmd, opt, ctrl, shift. Key: a single letter or "space".
    var hotkey: String = "opt+cmd+L"
    var auditMode: Bool = false

    static let url = Paths.support.appendingPathComponent("config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else {
            let fresh = Config()
            fresh.save()
            return fresh
        }
        // Decode leniently so a config written by an older build keeps working.
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config()))) as? [String: Any] ?? [:]
        let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let merged = defaults.merging(user) { _, new in new }
        if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
           let config = try? JSONDecoder().decode(Config.self, from: mergedData) {
            return config
        }
        return Config()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Config.url) }
    }

    var hasGoogleClient: Bool { !googleClientId.isEmpty && !googleClientSecret.isEmpty }

    private func minutes(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }

    func date(_ hhmm: String, on day: Date) -> Date {
        let m = minutes(hhmm)
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) ?? day
    }

    func isWorkTime(_ d: Date = Date()) -> Bool {
        let wd = Calendar.current.component(.weekday, from: d)
        guard workDays.contains(wd) else { return false }
        return d >= date(workStart, on: d) && d < date(workEnd, on: d)
    }
}
