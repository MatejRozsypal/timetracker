import AppKit
import ServiceManagement
import SwiftUI

@main
struct OETimeLogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var app

    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            exit(MainActor.assumeIsolated { Render.run(to: args[i + 1]) })
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: app.store, auth: app.auth, sync: app.sync, monitor: app.monitor, actions: app.menuActions)
        } label: {
            MenuLabel(store: app.store, monitor: app.monitor, auth: app.auth)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    let auth: GoogleAuth
    let sync: CalendarSync
    let monitor: ActivityMonitor
    let notifier = Notifier()
    let panel: EntryPanel

    private var hotKey: HotKey?
    private var syncTimer: Timer?
    private var sweepWindow: NSWindow?
    private var homeWindow: NSWindow?
    private var lastNudge: Date?

    override init() {
        store = Store()
        auth = GoogleAuth(store: store)
        sync = CalendarSync(store: store, auth: auth)
        monitor = ActivityMonitor(store: store)
        panel = EntryPanel(store: store)
        super.init()
    }

    var menuActions: MenuActions {
        MenuActions(
            logNow: { [weak self] in self?.panel.show(.now(.hotkey)) },
            openSweep: { [weak self] in self?.openSweep() },
            reload: { [weak self] in self?.reload() })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.ensureDay()
        registerHotKey()
        autoRegisterLoginItemOnce()

        notifier.setUp()
        notifier.onNudge = { [weak self] text in self?.handleNudgeReply(text) }
        notifier.onSweep = { [weak self] in self?.openSweep() }

        panel.onSave = { [weak self] model, parsed, rating in self?.save(model, parsed, rating) }
        panel.onCancel = { [weak self] model in self?.cancelled(model) }

        monitor.onReturn = { [weak self] away, back in self?.handleReturn(awayStart: away, back: back) }
        monitor.onTick = { [weak self] in self?.tick() }
        monitor.start()

        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        flush()

        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            openHome()
        }
    }

    /// Opening the app again (Spotlight, Finder, Launchpad) while it runs shows the
    /// home window, so the app is reachable even when the notch hides the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHome()
        return false
    }

    private func openHome() {
        let view = HomeView(hotkey: HotKey.display(store.config.hotkey)) {
            MenuView(store: self.store, auth: self.auth, sync: self.sync, monitor: self.monitor, actions: self.menuActions)
        }
        if homeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "OE Time Log"
            w.isReleasedWhenClosed = false
            homeWindow = w
        }
        homeWindow?.contentView = NSHostingView(rootView: view)
        homeWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        homeWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Triggers

    private func handleReturn(awayStart: Date, back: Date) {
        let config = store.config
        guard Calendar.current.isDate(awayStart, inSameDayAs: back) else {
            store.ensureDay(now: back)
            flush()
            return
        }
        let awayLength = back.timeIntervalSince(awayStart)
        guard awayLength >= config.awayMinutes * 60 else { return }

        store.addAway(AwaySegment(start: awayStart, end: back))
        let blockStart = store.blockStart
        if awayStart.timeIntervalSince(blockStart) >= 5 * 60 && config.isWorkTime(back) {
            // The boundary moves when the panel is saved or dismissed.
            panel.show(.beforeAway(start: blockStart, awayStart: awayStart, back: back))
        } else {
            store.setBoundary(max(blockStart, back))
        }
        monitor.resetActive()
        flush()
    }

    private func tick() {
        let config = store.config
        let now = Date()
        guard config.isWorkTime(now), !monitor.isAway, !panel.isVisible else { return }

        // Fallback nudge: icon turns amber at nudgeMinutes, a quiet banner 15 minutes later, then every 30.
        if monitor.activeSinceLog >= (config.nudgeMinutes + 15) * 60,
           lastNudge.map({ now.timeIntervalSince($0) > 30 * 60 }) ?? true {
            lastNudge = now
            notifier.post(.nudge, title: "\(Fmt.duration(monitor.activeSinceLog)) since your last log",
                          body: "What are you on? Reply with e.g. \"dob meta review g\" or click to open the panel.")
        }

        // End-of-day sweep reminder, once per day.
        if !store.sweepShownToday, now >= config.date(config.sweepTime, on: now) {
            store.markSweepShown()
            let unlogged = store.stats(now: now).unlogged
            notifier.post(.sweep, title: "Day sweep",
                          body: unlogged > 0 ? "\(Fmt.duration(unlogged)) unlogged today. Click to close the gaps." : "Click to review today.")
        }
    }

    private func handleNudgeReply(_ text: String?) {
        guard let text, !text.isEmpty else {
            panel.show(.now(.notification))
            return
        }
        let parsed = Parser.parse(text, codebook: store.codebook)
        guard parsed.isValid else {
            panel.show(.now(.notification), prefill: text)
            return
        }
        let start = store.blockStart, end = Date()
        store.add(start: start, end: end, parsed: parsed, rating: parsed.rating, trigger: .notification)
        store.setBoundary(end)
        monitor.resetActive()
        flush()
    }

    // MARK: Saving

    private func save(_ model: EntryModel, _ parsed: ParsedEntry, _ rating: Rating?) {
        let trigger: Trigger
        var boundary: Date?
        switch model.mode {
        case .now(let t):
            trigger = t
            boundary = model.end
        case .beforeAway(_, _, let back):
            trigger = .returned
            boundary = back
        case .gap(let g):
            trigger = .sweep
            if g.current { boundary = model.end }
        }
        store.add(start: model.start, end: model.end, parsed: parsed, rating: rating, trigger: trigger)
        if let boundary {
            store.setBoundary(max(boundary, store.state.lastBoundary ?? boundary))
            monitor.resetActive()
        }
        flush()
    }

    private func cancelled(_ model: EntryModel) {
        // Dismissing the "before you left" prompt leaves that block as a gap for the sweep.
        if case .beforeAway(_, _, let back) = model.mode {
            store.setBoundary(back)
        }
    }

    // MARK: Sweep

    private func openSweep() {
        let view = SweepView(
            store: store,
            logGap: { [weak self] gap in self?.panel.show(.gap(gap)) },
            markGap: { [weak self] gap, activity in self?.mark(gap, as: activity) })
        if sweepWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "OE Time Log"
            w.isReleasedWhenClosed = false
            sweepWindow = w
        }
        sweepWindow?.contentView = NSHostingView(rootView: view)
        sweepWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        sweepWindow?.makeKeyAndOrderFront(nil)
    }

    private func mark(_ gap: Gap, as activity: Activity) {
        let parsed = ParsedEntry(client: store.codebook.client("oe") ?? Client(code: "oe", name: "One Eighty"),
                                 activity: activity, energy: nil, note: "", rating: nil)
        store.add(start: gap.start, end: gap.end, parsed: parsed, rating: nil, trigger: .sweep)
        if gap.current {
            store.setBoundary(gap.end)
            monitor.resetActive()
        }
        flush()
    }

    // MARK: Misc

    private func flush() {
        Task { await sync.flush() }
    }

    private func reload() {
        store.reloadConfig()
        registerHotKey()
    }

    private func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(spec: store.config.hotkey) { [weak self] in
            MainActor.assumeIsolated { self?.panel.show(.now(.hotkey)) }
        }
        if hotKey == nil { auth.lastError = "Hotkey \"\(store.config.hotkey)\" could not be registered" }
    }

    private func autoRegisterLoginItemOnce() {
        let key = "didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
