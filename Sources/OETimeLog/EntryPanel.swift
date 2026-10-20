import AppKit
import SwiftUI

/// What the panel is asking about.
enum EntryMode {
    /// Hotkey or nudge: the block from the last boundary to now.
    case now(Trigger)
    /// Back at the Mac: the block until the user left, with the option to include the away time.
    case beforeAway(start: Date, awayStart: Date, back: Date)
    /// A gap from the sweep.
    case gap(Gap)
}

@MainActor
final class EntryModel: ObservableObject {
    enum Stage { case typing, rating }

    @Published var text = ""
    @Published var start: Date
    @Published var end: Date
    @Published var stage: Stage = .typing
    @Published var error: String?
    @Published var includeAway = false

    let mode: EntryMode
    let store: Store

    init(mode: EntryMode, store: Store, prefill: String = "") {
        self.mode = mode
        self.store = store
        self.text = prefill
        switch mode {
        case .now:
            start = store.blockStart
            end = Date()
        case .beforeAway(let s, let away, _):
            start = s
            end = away
        case .gap(let g):
            start = g.start
            end = g.end
        }
    }

    var headline: String {
        switch mode {
        case .now: return "What did you just finish?"
        case .beforeAway: return includeAway ? "Before and while you were away" : "Before you left"
        case .gap(let g): return g.away ? "Away from the Mac" : "Unlogged gap"
        }
    }

    var awayLength: TimeInterval? {
        if case .beforeAway(_, let away, let back) = mode { return back.timeIntervalSince(away) }
        return nil
    }

    var parsed: ParsedEntry { Parser.parse(text, codebook: store.codebook) }
    var suggestions: [(code: String, name: String)] { Array(Parser.suggestions(for: text, codebook: store.codebook).prefix(6)) }

    func toggleAway() {
        guard case .beforeAway(_, let away, let back) = mode else { return }
        includeAway.toggle()
        end = includeAway ? back : away
    }

    func nudgeEnd(_ minutes: Double) {
        let candidate = end.addingTimeInterval(minutes * 60)
        if candidate > start.addingTimeInterval(60) && candidate <= Date() { end = candidate }
    }

    func nudgeStart(_ minutes: Double) {
        let candidate = start.addingTimeInterval(minutes * 60)
        if candidate < end.addingTimeInterval(-60) { start = candidate }
    }
}

/// Floating quick-entry window. A real NSPanel (not the MenuBarExtra window)
/// because text focus inside MenuBarExtra is unreliable.
@MainActor
final class EntryPanel {
    var onSave: ((EntryModel, ParsedEntry, Rating?) -> Void)?
    var onCancel: ((EntryModel) -> Void)?

    private var panel: NSPanel?
    private var model: EntryModel?
    private var monitor: Any?
    private var previousApp: NSRunningApplication?
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ mode: EntryMode, prefill: String = "") {
        if isVisible {
            // A newer prompt replaces an open one only if the open one is a plain "now" prompt.
            if case .now = model?.mode { close(cancelled: false) } else { panel?.makeKeyAndOrderFront(nil); return }
        }
        let model = EntryModel(mode: mode, store: store, prefill: prefill)
        self.model = model

        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 300),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: EntryView(model: model))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.28 - panel.frame.height))
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Returns true when the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // Esc
            if model.stage == .rating { model.stage = .typing } else { close(cancelled: true) }
            return true
        }

        if model.stage == .rating {
            if let r = Rating(token: chars), !cmd {
                save(rating: r)
            } else if event.keyCode == 51 { // Delete goes back to editing
                model.stage = .typing
            }
            return true
        }

        switch event.keyCode {
        case 36, 76: // Return, Enter
            submit()
            return true
        case 48: // Tab completes the first suggestion
            if let first = model.suggestions.first { model.text = Parser.complete(model.text, with: first.code) }
            return true
        case 126: // Up
            shift ? model.nudgeStart(-5) : model.nudgeEnd(5)
            return true
        case 125: // Down
            shift ? model.nudgeStart(5) : model.nudgeEnd(-5)
            return true
        default:
            break
        }

        if cmd, let n = Int(chars), (1...8).contains(n) {
            let recent = store.recentCodes
            if n <= recent.count { model.text = recent[n - 1] + " " }
            return true
        }
        if cmd, chars == "e" {
            model.toggleAway()
            return true
        }
        return false
    }

    private func submit() {
        guard let model else { return }
        if model.text.trimmingCharacters(in: .whitespaces).isEmpty, let last = store.entries.last(where: { !$0.isOff }) {
            // Empty Enter repeats the last entry.
            model.text = last.title
        }
        let parsed = model.parsed
        if let err = parsed.error ?? (parsed.isValid ? nil : "Type a client and an activity code") {
            model.error = err
            return
        }
        model.error = nil
        if let r = parsed.rating { save(rating: r) } else { model.stage = .rating }
    }

    private func save(rating: Rating) {
        guard let model else { return }
        let parsed = model.parsed
        guard parsed.isValid else { model.stage = .typing; return }
        onSave?(model, parsed, rating)
        close(cancelled: false)
    }

    private func close(cancelled: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if cancelled, let model { onCancel?(model) }
        panel?.orderOut(nil)
        panel = nil
        model = nil
        previousApp?.activate()
        previousApp = nil
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct EntryView: View {
    @ObservedObject var model: EntryModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.headline).font(.headline)
                Spacer()
                Text(Fmt.range(model.start, model.end)).monospacedDigit()
                Text(Fmt.duration(model.end.timeIntervalSince(model.start)))
                    .foregroundStyle(.secondary).monospacedDigit()
            }

            if let away = model.awayLength {
                Text(model.includeAway
                     ? "Includes the \(Fmt.duration(away)) away. Cmd+E to log only until you left."
                     : "You were away \(Fmt.duration(away)). Cmd+E to include it (a call, a meeting).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.stage == .typing {
                TextField("client activity [+|-] note [g|o|r]", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .medium))
                    .focused($focused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

                if let err = model.error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                if !model.suggestions.isEmpty {
                    FlowRow(items: model.suggestions.map { "\($0.code)  \($0.name)" })
                }

                let recent = model.store.recentCodes
                if !recent.isEmpty {
                    Text(recent.enumerated().map { "Cmd+\($0.offset + 1) \($0.element)" }.joined(separator: "   "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                Text("Enter: rate   Tab: complete   Up/Down: end 5 min   Shift+Up/Down: start   empty Enter: repeat last   Esc")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(model.text).font(.system(size: 18, weight: .medium))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Rating.allCases, id: \.self) { r in
                        HStack(spacing: 10) {
                            Text(r.rawValue.prefix(1).uppercased())
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(r.color))
                                .foregroundStyle(.white)
                            Text(r.anchor)
                        }
                    }
                }
                Text("Press G, O or R to save   Esc: back").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

struct FlowRow: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(4), id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
    }
}

extension Rating {
    var color: Color {
        switch self {
        case .green: return Color(red: 0.20, green: 0.55, blue: 0.27)  // Basil
        case .orange: return Color(red: 0.96, green: 0.45, blue: 0.13) // Tangerine
        case .red: return Color(red: 0.84, green: 0.18, blue: 0.13)    // Tomato
        }
    }
}
