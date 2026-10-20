import AppKit
import ServiceManagement
import SwiftUI

// MARK: Menu bar label

struct MenuLabel: View {
    @ObservedObject var store: Store
    @ObservedObject var monitor: ActivityMonitor
    @ObservedObject var auth: GoogleAuth

    var body: some View {
        let nudge = monitor.activeSinceLog >= store.config.nudgeMinutes * 60
        if !auth.signedIn {
            Image(systemName: "exclamationmark.circle")
        } else if nudge {
            HStack(spacing: 3) {
                Image(systemName: "clock.badge.exclamationmark")
                Text(Fmt.duration(monitor.activeSinceLog))
            }
        } else {
            Image(systemName: "clock")
        }
    }
}

// MARK: Menu bar window

struct MenuView: View {
    @ObservedObject var store: Store
    @ObservedObject var auth: GoogleAuth
    @ObservedObject var sync: CalendarSync
    @ObservedObject var monitor: ActivityMonitor
    let actions: MenuActions

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let stats = store.stats()
        let gaps = store.gaps().filter { !$0.current }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                if let ds = store.state.dayStart {
                    Text("started \(Fmt.time.string(from: ds))").foregroundStyle(.secondary).font(.caption)
                }
            }

            HStack(spacing: 16) {
                stat("Logged", Fmt.duration(stats.logged))
                stat("Unlogged", Fmt.duration(stats.unlogged))
                stat("Focus", stats.focusScore.map { "\($0)" } ?? "n/a")
            }

            FocusBar(stats: stats).frame(height: 8)

            Text("Current block: \(Fmt.range(store.blockStart, Date())) (\(Fmt.duration(Date().timeIntervalSince(store.blockStart))))")
                .font(.caption).foregroundStyle(.secondary)

            if !store.today.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.today.suffix(6).reversed()) { e in
                        HStack(spacing: 6) {
                            Circle().fill(e.rating?.color ?? .gray.opacity(0.4)).frame(width: 8, height: 8)
                            Text(Fmt.time.string(from: e.start)).monospacedDigit().foregroundStyle(.secondary)
                            Text(e.isOff ? "off" : e.title).lineLimit(1)
                            Spacer()
                            Text(Fmt.duration(e.duration)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            Button("Log now   \(HotKey.display(store.config.hotkey))") { actions.logNow() }
            Button(gaps.isEmpty ? "Day sweep" : "Day sweep (\(gaps.count) gaps)") { actions.openSweep() }

            Divider()

            if !store.config.hasGoogleClient {
                Text("Add googleClientId and googleClientSecret to config.json, then Reload.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if auth.signedIn {
                HStack {
                    Text(sync.pending == 0 ? "Calendar in sync" : "\(sync.pending) waiting to sync")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync now") { Task { await sync.flush() } }.disabled(sync.syncing)
                }
            } else {
                Button("Sign in with Google") { Task { await auth.signIn(); await sync.flush() } }
            }
            if let err = auth.lastError ?? sync.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            HStack {
                Button("Open data folder") { NSWorkspace.shared.open(Paths.support) }
                Button("Reload config") { actions.reload() }
                Spacer()
                if auth.signedIn { Button("Sign out") { auth.signOut() } }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 340)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FocusBar: View {
    let stats: Store.DayStats
    var body: some View {
        GeometryReader { geo in
            let total = max(1, stats.green + stats.orange + stats.red + stats.unrated + stats.unlogged)
            HStack(spacing: 1) {
                seg(stats.green, Rating.green.color, total, geo.size.width)
                seg(stats.orange, Rating.orange.color, total, geo.size.width)
                seg(stats.red, Rating.red.color, total, geo.size.width)
                seg(stats.unrated, .gray.opacity(0.5), total, geo.size.width)
                seg(stats.unlogged, .gray.opacity(0.2), total, geo.size.width)
            }
            .clipShape(Capsule())
        }
    }

    private func seg(_ v: TimeInterval, _ c: Color, _ total: TimeInterval, _ w: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: max(0, CGFloat(v / total) * w))
    }
}

/// Callbacks the menu needs from the app delegate.
struct MenuActions {
    let logNow: () -> Void
    let openSweep: () -> Void
    let reload: () -> Void
}

// MARK: Home window

/// Shown on first launch and whenever the app is opened again while running.
struct HomeView<Content: View>: View {
    let hotkey: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("OE Time Log is running").font(.title3.bold())
                Text("Press \(hotkey) anywhere when you finish something. The app lives in the menu bar as a clock icon. If you cannot see it, the notch is hiding it: quit an icon or two, or just use \(hotkey). Open the app again any time to get back here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Divider()
            content()
        }
        .frame(width: 340)
    }
}

// MARK: Sweep window

struct SweepView: View {
    @ObservedObject var store: Store
    let logGap: (Gap) -> Void
    let markGap: (Gap, Activity) -> Void

    var body: some View {
        let gaps = store.gaps()
        VStack(alignment: .leading, spacing: 12) {
            Text("Day sweep").font(.title2.bold())
            Text("Every stretch since you started today that has no entry. Log it, or mark it off or unknown. Away stretches are usually breaks.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if gaps.isEmpty {
                Text("Nothing unaccounted for. Done.").padding(.vertical, 20)
            } else {
                ForEach(gaps) { gap in
                    HStack(spacing: 10) {
                        Image(systemName: gap.away ? "moon.zzz" : (gap.current ? "play.circle" : "questionmark.circle"))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(Fmt.range(gap.start, gap.end)).monospacedDigit()
                            Text(gap.current ? "current block" : (gap.away ? "away from the Mac" : "at the Mac, unlogged"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(Fmt.duration(gap.duration)).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Log") { logGap(gap) }
                        Button("Off") { markGap(gap, Codebook.off) }
                        Button("Unknown") { markGap(gap, Codebook.unknown) }
                    }
                    Divider()
                }
                let away = gaps.filter { $0.away && !$0.current }
                if !away.isEmpty {
                    Button("Mark all away stretches as off") { away.forEach { markGap($0, Codebook.off) } }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
