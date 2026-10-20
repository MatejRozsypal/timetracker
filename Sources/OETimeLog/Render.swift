import AppKit
import SwiftUI

/// `OETimeLog --render <dir>` draws the main views offscreen to PNGs, for
/// checking layout without Screen Recording permission.
@MainActor
enum Render {
    static func run(to dir: String) -> Int32 {
        _ = NSApplication.shared
        let store = Store()
        let auth = GoogleAuth(store: store)
        let sync = CalendarSync(store: store, auth: auth)
        let monitor = ActivityMonitor(store: store)
        let actions = MenuActions(logNow: {}, openSweep: {}, reload: {})

        let typing = EntryModel(mode: .now(.hotkey), store: store, prefill: "dob me")
        let rating = EntryModel(mode: .beforeAway(start: Date().addingTimeInterval(-3600),
                                                  awayStart: Date().addingTimeInterval(-1500),
                                                  back: Date()), store: store, prefill: "dob meta + scaling test review")
        rating.stage = .rating

        let shots: [(String, AnyView)] = [
            ("panel-typing", AnyView(EntryView(model: typing))),
            ("panel-rating", AnyView(EntryView(model: rating))),
            ("menu", AnyView(MenuView(store: store, auth: auth, sync: sync, monitor: monitor, actions: actions))),
            ("sweep", AnyView(SweepView(store: store, logGap: { _ in }, markGap: { _, _ in }))),
        ]
        for (name, view) in shots {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
        return 0
    }
}
