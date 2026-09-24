import Foundation
import CoreBluetooth

/// One temple's link: its peripheral, its characteristics, its outbox, and the
/// two answers a transfer waits on. Main thread only.
///
/// Per arm on purpose. The SDK used to keep one `writeConfirmation` and one
/// `imageVerdict` closure for both, so an answer from the arm that was not
/// being waited on could satisfy the wait for the one that was.
final class ArmLink {
    let side: G1Side
    var peripheral: CBPeripheral?
    var writeChar: CBCharacteristic?
    var notifyChar: CBCharacteristic?

    private var outbox: ArmOutbox?
    private var pendingWrite: OneShot<Bool>?
    private var pendingVerdict: OneShot<Bool?>?

    init(side: G1Side) {
        self.side = side
    }

    func attachOutbox(_ outbox: ArmOutbox) {
        self.outbox = outbox
    }

    var isLinked: Bool { peripheral?.state == .connected }
    var isLinkedOrLinking: Bool { peripheral?.state == .connected || peripheral?.state == .connecting }
    /// Linked **and** discovered: the only state in which a write goes anywhere.
    var isWritable: Bool { isLinked && writeChar != nil }

    // MARK: Plain writes

    func enqueue(_ data: Data, delay: TimeInterval = 0, sent: (() -> Void)? = nil) {
        outbox?.enqueue(data, delay: delay, sent: sent)
    }

    func pause() { outbox?.pause() }
    func resume() { outbox?.resume() }

    /// The outbox's write: unresponded, as every command but an image goes.
    func writePlain(_ data: Data) {
        guard let p = peripheral, let c = writeChar else {
            trace("\(side) not writable; dropped \(EvenG1SDK.hex(data))")
            return
        }
        p.writeValue(data, for: c, type: .withoutResponse)
    }

    // MARK: Confirmed writes (images)

    /// Writes with response and waits for the peripheral to confirm it.
    @MainActor
    @discardableResult
    func writeConfirmed(_ data: Data, timeout: TimeInterval) async -> Bool {
        guard let p = peripheral, let c = writeChar else { return false }
        let shot = OneShot<Bool>()
        pendingWrite = shot
        p.writeValue(data, for: c, type: .withResponse)
        let ok = await shot.wait(timeout: timeout, onTimeout: false)
        if pendingWrite === shot { pendingWrite = nil }
        return ok
    }

    /// Writes the CRC packet and waits for the arm's verdict on the frame.
    /// `nil` if it never answers.
    @MainActor
    func writeAwaitingVerdict(
        _ data: Data, writeTimeout: TimeInterval, verdictTimeout: TimeInterval
    ) async -> Bool? {
        let shot = OneShot<Bool?>()
        pendingVerdict = shot
        await writeConfirmed(data, timeout: writeTimeout)
        let verdict = await shot.wait(timeout: verdictTimeout, onTimeout: nil)
        if pendingVerdict === shot { pendingVerdict = nil }
        return verdict
    }

    func resolveWrite(_ ok: Bool) {
        pendingWrite?.resolve(ok)
    }

    func resolveVerdict(_ accepted: Bool) {
        pendingVerdict?.resolve(accepted)
    }

    /// The peripheral went away. Whatever was waiting on it is answered with
    /// failure, and whatever was queued for it is dropped.
    func linkDropped() {
        pendingWrite?.resolve(false)
        pendingVerdict?.resolve(nil)
        pendingWrite = nil
        pendingVerdict = nil
        writeChar = nil
        notifyChar = nil
        outbox?.clear()
        outbox?.resume()
    }
}

/// A value that arrives once, from a callback or from a timeout, whichever is
/// first — and only once.
///
/// `CheckedContinuation` traps on a second resume, and a BLE delegate does not
/// promise to call once (`sendPing` crashed JARVIX on exactly that). Both
/// sources resolve the same latch; the first wins and the rest are dropped.
/// Main thread only, like everything that touches a peripheral here.
final class OneShot<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var early: Value?
    private var settled = false

    func resolve(_ value: Value) {
        guard !settled else { return }
        settled = true
        if let continuation = continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else {
            early = value
        }
    }

    @MainActor
    func wait(timeout: TimeInterval, onTimeout: Value) async -> Value {
        if settled, let early = early { return early }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(onTimeout)
            }
        }
    }
}
