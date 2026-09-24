import XCTest
@testable import EvenG1Kit

/// A clock the test moves, so a whole connect sequence runs in no time and the
/// order the packets would have gone out in can be asserted.
private final class FakeClock {
    var now: TimeInterval = 0
    private var timers: [(at: TimeInterval, run: () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        timers.append((now + delay, work))
    }

    /// Runs every timer due by `t`, in order, moving the clock as it goes.
    func advance(to t: TimeInterval) {
        while let next = timers.enumerated().min(by: { $0.element.at < $1.element.at }),
              next.element.at <= t {
            timers.remove(at: next.offset)
            now = max(now, next.element.at)
            next.element.run()
        }
        now = t
    }
}

final class OutboxTests: XCTestCase {
    private var clock: FakeClock!
    private var written: [(at: TimeInterval, data: Data)] = []

    override func setUp() {
        clock = FakeClock()
        written = []
    }

    private func makeOutbox(gap: TimeInterval = 0.1) -> ArmOutbox {
        ArmOutbox(
            gap: gap,
            now: { [clock] in clock!.now },
            schedule: { [clock] delay, work in clock!.schedule(delay, work) },
            write: { [weak self, clock] data in self?.written.append((clock!.now, data)) }
        )
    }

    private func packet(_ byte: UInt8) -> Data { Data([byte]) }

    func testFirstWriteGoesOutAtOnce() {
        let outbox = makeOutbox()
        outbox.enqueue(packet(1))
        XCTAssertEqual(written.map(\.data), [packet(1)])
        XCTAssertEqual(written[0].at, 0)
    }

    func testConsecutiveWritesKeepTheGap() {
        // Back-to-back writes are dropped on the right side: the gap is the rule.
        let outbox = makeOutbox(gap: 0.1)
        outbox.enqueue(packet(1))
        outbox.enqueue(packet(2))
        outbox.enqueue(packet(3))
        XCTAssertEqual(written.count, 1, "the second write must wait for the gap")
        clock.advance(to: 1)
        XCTAssertEqual(written.map(\.data), [packet(1), packet(2), packet(3)])
        XCTAssertEqual(written.map(\.at), [0, 0.1, 0.2])
    }

    func testDelayHoldsAnItemWithoutHoldingTheOnesBehindIt() {
        // The right arm gets a shared command 100 ms after the left; a
        // later command must not go out before an earlier one.
        let outbox = makeOutbox(gap: 0.01)
        outbox.enqueue(packet(1), delay: 0.5)
        outbox.enqueue(packet(2))
        XCTAssertEqual(written.count, 0, "order is preserved: 2 waits behind 1")
        clock.advance(to: 0.6)
        XCTAssertEqual(written.map(\.data), [packet(1), packet(2)])
        XCTAssertEqual(written[0].at, 0.5, accuracy: 1e-9)
    }

    func testPauseHoldsEverythingAndResumeDrainsInOrder() {
        // Nothing may interleave with an image transfer. A heartbeat raised
        // mid-transfer waits its turn instead of landing inside the frame.
        let outbox = makeOutbox(gap: 0.1)
        outbox.pause()
        outbox.enqueue(packet(0x25))   // heartbeat
        outbox.enqueue(packet(0x2C))   // battery query
        clock.advance(to: 5)
        XCTAssertEqual(written.count, 0, "paused outbox must not write")
        XCTAssertEqual(outbox.pendingCount, 2)
        outbox.resume()
        clock.advance(to: 6)
        XCTAssertEqual(written.map(\.data), [packet(0x25), packet(0x2C)])
        XCTAssertEqual(written[1].at - written[0].at, 0.1, accuracy: 1e-9)
    }

    func testSentCallbackFiresAfterTheWrite() {
        // `sendToBoth` schedules the right arm from this callback, so the lag
        // is measured from when the left write really went out.
        let outbox = makeOutbox(gap: 0.1)
        var sentAt: TimeInterval?
        outbox.enqueue(packet(1))
        outbox.enqueue(packet(2)) { [clock] in sentAt = clock!.now }
        clock.advance(to: 1)
        XCTAssertEqual(sentAt, 0.1)
        XCTAssertEqual(written.count, 2)
    }

    func testClearDropsWhatWasWaiting() {
        let outbox = makeOutbox(gap: 0.1)
        outbox.enqueue(packet(1))
        outbox.enqueue(packet(2))
        outbox.clear()
        clock.advance(to: 1)
        XCTAssertEqual(written.map(\.data), [packet(1)], "the queued item died with the link")
    }

    func testResumeWithoutPauseIsHarmless() {
        let outbox = makeOutbox()
        outbox.resume()
        outbox.enqueue(packet(1))
        XCTAssertEqual(written.count, 1)
    }
}

final class OneShotTests: XCTestCase {
    @MainActor
    func testFirstAnswerWinsAndSecondIsDropped() async {
        let shot = OneShot<Bool>()
        shot.resolve(true)
        shot.resolve(false)  // a second callback must not trap or override
        let value = await shot.wait(timeout: 1, onTimeout: false)
        XCTAssertTrue(value)
    }

    @MainActor
    func testTimeoutResolvesWhenNothingAnswers() async {
        let shot = OneShot<Bool?>()
        let value = await shot.wait(timeout: 0.05, onTimeout: nil)
        XCTAssertNil(value)
    }

    @MainActor
    func testLateAnswerAfterTimeoutIsIgnored() async {
        let shot = OneShot<Bool>()
        let value = await shot.wait(timeout: 0.02, onTimeout: false)
        shot.resolve(true)
        XCTAssertFalse(value)
    }
}
