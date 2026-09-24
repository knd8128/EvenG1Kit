import Foundation

/// One arm's outgoing queue: the order, the pacing and the holds, with no
/// Bluetooth in it.
///
/// Every rule here was paid for on hardware and used to live as an
/// `asyncAfter` somewhere in the SDK: the right arm drops back-to-back writes,
/// so consecutive writes keep a gap; a command written into the middle of an
/// image becomes part of the image, so the queue pauses while a frame is on
/// the wire and drains afterwards; and a write is a write only once the arm is
/// writable, so nothing here touches a peripheral — it calls `write`, and the
/// owner decides what that means. Time and scheduling are injected for the
/// same reason: a test can run a whole connect sequence in a millisecond and
/// assert the order the packets would have gone out in.
final class ArmOutbox {
    struct Item {
        let data: Data
        /// Not before this instant, on the injected clock.
        let notBefore: TimeInterval
        /// Runs after the write is handed over, on the caller's thread.
        let sent: (() -> Void)?
    }

    /// Minimum spacing between two writes to the same arm.
    let gap: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let write: (Data) -> Void

    private var queue: [Item] = []
    private var lastWriteAt: TimeInterval = -.greatestFiniteMagnitude
    private var timerArmed = false
    private(set) var isPaused = false

    init(
        gap: TimeInterval,
        now: @escaping () -> TimeInterval,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        write: @escaping (Data) -> Void
    ) {
        self.gap = gap
        self.now = now
        self.schedule = schedule
        self.write = write
    }

    var pendingCount: Int { queue.count }

    func enqueue(_ data: Data, delay: TimeInterval = 0, sent: (() -> Void)? = nil) {
        queue.append(Item(data: data, notBefore: now() + delay, sent: sent))
        pump()
    }

    /// Stops dispatching. Items keep queueing and go out, in order, on `resume`.
    func pause() { isPaused = true }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        pump()
    }

    /// Drops everything waiting. For a link that just died: the arm it was
    /// meant for is gone, and replaying it on the next one would restore state
    /// nobody asked for.
    func clear() { queue.removeAll() }

    private func pump() {
        guard !isPaused, !timerArmed, let next = queue.first else { return }
        let readyAt = max(next.notBefore, lastWriteAt + gap)
        let wait = readyAt - now()
        if wait > 0 {
            timerArmed = true
            schedule(wait) { [weak self] in
                guard let self = self else { return }
                self.timerArmed = false
                self.pump()
            }
            return
        }
        queue.removeFirst()
        lastWriteAt = now()
        write(next.data)
        next.sent?()
        pump()
    }
}
