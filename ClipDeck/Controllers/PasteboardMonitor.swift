import AppKit
import os

/// The watcher uses a utility QoS timer to compare the general pasteboard's change count. The timer
/// stops while the screen is locked, the Mac sleeps, or the session is inactive.
final class PasteboardMonitor: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let classifier: PasteboardClassifier
    private let onCapture: @Sendable (Capture) -> Void
    private let queue = DispatchQueue(label: "com.kevster.clipdeck.capture", qos: .utility)

    // Reads and writes use only `queue`.
    private var timer: DispatchSourceTimer?
    private var lastChangeCount = 0
    private var gate = PollingGate()
    private var isStarted = false

    /// ClipDeck splits its writes between the writing thread and `queue` so neither waits for the
    /// other.
    private let ownWrites = OSAllocatedUnfairLock(initialState: OwnWrites())

    // Use the main thread only.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        pasteboard: NSPasteboard = .general,
        classifier: PasteboardClassifier = PasteboardClassifier(),
        onCapture: @escaping @Sendable (Capture) -> Void
    ) {
        self.pasteboard = pasteboard
        self.classifier = classifier
        self.onCapture = onCapture
    }

    /// It starts polling, but does not capture content that was already on the pasteboard.
    func start() {
        queue.async { [self] in
            isStarted = true
            lastChangeCount = pasteboard.changeCount
            updateTimer()
        }
        observeSystemState()
    }

    func stop() {
        queue.async { [self] in
            isStarted = false
            updateTimer()
        }
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    func pause(_ reason: PauseReasons) {
        queue.async { [self] in
            if gate.pause(reason) {
                Log.capture.info("Capture paused")
                updateTimer()
            }
        }
    }

    func resume(_ reason: PauseReasons) {
        queue.async { [self] in
            if gate.resume(reason) {
                Log.capture.info("Capture resumed")
                updateTimer()
            }
        }
    }

    /// ClipDeck writes to the pasteboard and records the returned change count, so polls do not
    /// capture its own write. `write` returns the count from its own `clearContents()`, not from a
    /// later read. Thus, ClipDeck still captures another app's write right afterward. It never
    /// waits for a poll to finish classifying. Polls only defer while a write is in flight.
    func writeOwn(_ write: (NSPasteboard) -> Int?) -> Bool {
        ownWrites.withLock { $0.inFlight += 1 }
        let changeCount = write(pasteboard)
        ownWrites.withLock {
            $0.inFlight -= 1
            if let changeCount { $0.changeCounts.insert(changeCount) }
        }
        return changeCount != nil
    }

    private func updateTimer() {
        let shouldRun = isStarted && gate.isOpen
        if shouldRun, timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + Constants.Capture.pollInterval,
                repeating: Constants.Capture.pollInterval,
                leeway: Constants.Capture.pollLeeway
            )
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        } else if !shouldRun, let source = timer {
            source.cancel()
            timer = nil
        }
    }

    private func tick() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        let decision = ownWrites.withLock { state -> OwnWrites.Decision in
            if state.inFlight > 0 { return .wait }
            let isOwn = state.changeCounts.contains(changeCount)
            state.changeCounts = state.changeCounts.filter { $0 > changeCount }
            return isOwn ? .skip : .read
        }
        switch decision {
        case .wait:
            return
        case .skip:
            lastChangeCount = changeCount
            return
        case .read:
            lastChangeCount = changeCount
        }

        switch classifier.classify(PasteboardSnapshot.read(from: pasteboard)) {
        case .capture(let capture):
            onCapture(capture)
        case .skip(.tooLarge(let bytes)):
            Log.capture.notice("Skipped text larger than the size cap (\(bytes) bytes)")
        case .skip(let reason):
            Log.capture.debug("Skipped pasteboard: \(String(describing: reason), privacy: .public)")
        }
    }

    private func observeSystemState() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, PauseReasons, Bool)] = [
            (workspace, NSWorkspace.willSleepNotification, .systemAsleep, true),
            (workspace, NSWorkspace.didWakeNotification, .systemAsleep, false),
            (workspace, NSWorkspace.screensDidSleepNotification, .screensAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, false),
        ]
        observers = pairs.map { center, name, reason, pauses in
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if pauses { self?.pause(reason) } else { self?.resume(reason) }
            }
            return (center, observer)
        }
    }
}

private struct OwnWrites {
    enum Decision {
        /// A write is in progress. Check again on the next tick.
        case wait
        case skip
        case read
    }

    var inFlight = 0
    var changeCounts: Set<Int> = []
}
