import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// Watches for breakpoints: going away (lock, sleep, idle) and coming back,
/// plus counts active minutes since the last log for the fallback nudge.
/// Needs no Accessibility or Screen Recording permission.
@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var activeSinceLog: TimeInterval = 0
    @Published private(set) var isAway = false

    /// Called with (awayStart, returnedAt) when the user comes back.
    var onReturn: ((Date, Date) -> Void)?
    /// Called every tick so the app can decide on nudges and the sweep.
    var onTick: (() -> Void)?

    private var awayStart: Date?
    /// While the screen is locked only the unlock notification counts as coming back
    /// (typing the password, or idle being near zero right after locking, must not).
    private var locked = false
    private var timer: Timer?
    private let tick: TimeInterval = 30
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.locked = true
                self?.wentAway(at: Date())
            }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.locked = false
                self?.cameBack(at: Date())
            }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway(at: Date()) }
        }
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway(at: Date()) }
        }
        // Wake alone does not mean the user is back (lid open, lock screen showing):
        // the unlock notification or fresh input decides that.

        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func resetActive() {
        activeSinceLog = 0
    }

    private func poll() {
        let idle = Self.secondsIdle()
        let threshold = store.config.awayMinutes * 60

        if isAway {
            if !locked && idle < tick { cameBack(at: Date()) }
        } else if idle >= threshold && !Self.displaySleepPrevented() {
            // Calls and video hold a display-sleep assertion; idle during them is not "away".
            wentAway(at: Date().addingTimeInterval(-idle))
        } else if idle < 120 {
            activeSinceLog += tick
        }
        onTick?()
    }

    private func wentAway(at date: Date) {
        guard !isAway else { return }
        isAway = true
        awayStart = date
    }

    private func cameBack(at date: Date) {
        guard isAway, let start = awayStart else { return }
        isAway = false
        awayStart = nil
        onReturn?(start, date)
    }

    static func secondsIdle() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// True when some app (Zoom, Meet in a browser, a video player) prevents display sleep.
    static func displaySleepPrevented() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess,
              let status = dict?.takeRetainedValue() as? [String: Int] else { return false }
        return (status["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }
}
