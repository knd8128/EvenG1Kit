//
//  EvenG1SDK.swift
//  EvenG1Kit
//
//  Created by Abraham Rubio on 21/09/25.
//

import Foundation
import CoreBluetooth
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// What the SDK tells its host. Every method has an empty default, so a host
/// implements what it uses and nothing else.
///
/// Called on the main thread, always: the central manager is created on it and
/// every callback the SDK makes is a consequence of one of its callbacks.
public protocol EvenG1Delegate: AnyObject {
    // Discovery / selection
    func glasses(_ sdk: EvenG1SDK, didUpdateScanResults results: [EvenG1SDK.Discovered],
                 pairs: [EvenG1SDK.Pair])
    func glasses(_ sdk: EvenG1SDK, didRequirePairSelection pairs: [EvenG1SDK.Pair])
    func glassesDidScanTimeout(_ sdk: EvenG1SDK)

    // Connection
    func glasses(_ sdk: EvenG1SDK, didChangeState state: EvenG1SDK.State)
    func glasses(_ sdk: EvenG1SDK, didFailToConnect side: G1Side?, name: String?, error: Error?)
    func glasses(_ sdk: EvenG1SDK, didBeginReconnectAttempt count: Int, side: G1Side)
    func glasses(_ sdk: EvenG1SDK, didLose side: G1Side)

    // Events
    func glasses(_ sdk: EvenG1SDK, didReceiveTouch gesture: G1Touch, from side: G1Side)
    func glasses(_ sdk: EvenG1SDK, didReceiveMicAudio data: Data)
    /// Every decoded inbound packet, after the SDK has applied it to its own
    /// published state. For hosts that want the stream, not the summary.
    func glasses(_ sdk: EvenG1SDK, didReceive event: G1Inbound, from side: G1Side)
}

public extension EvenG1Delegate {
    func glasses(_ sdk: EvenG1SDK, didUpdateScanResults results: [EvenG1SDK.Discovered],
                 pairs: [EvenG1SDK.Pair]) {}
    func glasses(_ sdk: EvenG1SDK, didRequirePairSelection pairs: [EvenG1SDK.Pair]) {}
    func glassesDidScanTimeout(_ sdk: EvenG1SDK) {}
    func glasses(_ sdk: EvenG1SDK, didChangeState state: EvenG1SDK.State) {}
    func glasses(_ sdk: EvenG1SDK, didFailToConnect side: G1Side?, name: String?, error: Error?) {}
    func glasses(_ sdk: EvenG1SDK, didBeginReconnectAttempt count: Int, side: G1Side) {}
    func glasses(_ sdk: EvenG1SDK, didLose side: G1Side) {}
    func glasses(_ sdk: EvenG1SDK, didReceiveTouch gesture: G1Touch, from side: G1Side) {}
    func glasses(_ sdk: EvenG1SDK, didReceiveMicAudio data: Data) {}
    func glasses(_ sdk: EvenG1SDK, didReceive event: G1Inbound, from side: G1Side) {}
}

/// The Even Realities G1, as one object.
///
/// The glasses are two BLE peripherals that share a channel name. This class
/// pairs them, keeps both links alive, publishes what the hardware reports, and
/// turns every command into the packets each arm expects. The rules of the
/// wire — the left arm first and the right 100 ms later, a gap between writes
/// to the same arm, nothing at all while an image is on the wire — live in
/// each arm's `ArmOutbox`, where they can be tested without a radio.
///
/// Main thread only. The central manager is created with the main queue and
/// every entry point expects to be called there.
public final class EvenG1SDK: NSObject, ObservableObject {
    public static let shared = EvenG1SDK()

    // MARK: - Public Types

    public enum State: Equatable {
        case idle
        case bluetoothOff
        case scanning
        case connecting
        /// Which arms are linked **and writable**. An arm whose write
        /// characteristic has not been discovered yet is not connected: what is
        /// sent to it is dropped with no error.
        case connected(left: Bool, right: Bool)
        case error(G1Error)
    }

    public enum SideHint: String { case left, right, unknown }

    public struct Discovered: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        public let side: SideHint
        public let channel: String?
    }

    public struct Pair: Identifiable, Equatable {
        public var id: String { channel ?? "unknown" }
        public let channel: String?
        public var left: Discovered?
        public var right: Discovered?

        public var isComplete: Bool { left != nil && right != nil }
    }

    /// What an image transfer actually did, per arm. `nil` means the arm never
    /// answered the checksum packet at all.
    ///
    /// The verdict is not inferred from chunk replies — this firmware does not
    /// answer the data packets. It answers the end marker with `0x20 0xC9`, and
    /// the CRC packet with the checksum it computed plus a status byte, `0xC9`
    /// intact or `0xCA` not. That byte is the only truth available about a
    /// display that cannot be seen from here.
    public struct ImageTransferReport: Equatable, Sendable {
        public let leftAccepted: Bool?
        public let rightAccepted: Bool?

        public init(leftAccepted: Bool?, rightAccepted: Bool?) {
            self.leftAccepted = leftAccepted
            self.rightAccepted = rightAccepted
        }

        public func accepted(by side: G1Side) -> Bool? {
            side == .left ? leftAccepted : rightAccepted
        }

        /// At least one arm took the frame.
        public var anyAccepted: Bool { leftAccepted == true || rightAccepted == true }
    }

    // MARK: - Published state

    @Published public private(set) var state: State = .idle
    @Published public private(set) var scanResults: [Discovered] = []
    @Published public private(set) var pairs: [String: Pair] = [:]
    @Published public private(set) var lastError: G1Error?

    @Published public private(set) var batteryInfo = EvenG1BatteryInfo(left: 0, right: 0, caseBattery: nil)
    @Published public private(set) var glassesState: EvenG1GlassesState = .unknown
    /// The level as the hardware has it, `0...42`; nil until it has answered.
    @Published public private(set) var brightnessLevel: Int?
    /// Mirrors silent mode on the glasses: set by `setSilentMode(enabled:)` and
    /// updated when the wearer triple-taps the TouchBar.
    @Published public private(set) var isSilentMode = false
    @Published public private(set) var dashPosition: Int?
    @Published public private(set) var wearDetectionEnabled: Bool?
    @Published public private(set) var firmwareVersion: String?
    @Published public private(set) var serialNumber: String?
    @Published public private(set) var macAddress: String?
    /// True while a frame is on the wire. Everything else waits.
    @Published public private(set) var isTransferringImage = false

    public weak var delegate: EvenG1Delegate?

    // MARK: - Wire rules

    /// Minimum spacing between two writes to the same arm. Back-to-back writes
    /// are dropped on the right side, and 100 ms is the gap the left→right
    /// stagger has always used.
    static let writeGap: TimeInterval = 0.1
    /// The right arm gets each shared command this long after the left.
    static let rightArmLag: TimeInterval = 0.1
    /// A confirmed write should come back in milliseconds; the timeout is only
    /// so a silent link cannot wedge a transfer.
    static let writeTimeout: TimeInterval = 1.0
    /// How long to wait for the arm's verdict on the CRC packet.
    static let verdictTimeout: TimeInterval = 1.5
    /// How many times to offer a frame to an arm that turns it down. The left
    /// arm has been seen refusing the first frame after a connection and
    /// taking the next.
    static let transferAttempts = 2
    /// Keepalive interval. Also the tick the other refreshes are counted in;
    /// the glasses drop the link after about 32 s of silence.
    static let upkeepInterval: TimeInterval = 8
    /// Battery every twenty ticks; it does not move faster than that.
    static let batteryEveryTicks = 20
    static let reconnectAttempts = 3

    // MARK: - Internals

    private var central: CBCentralManager!
    private let left: ArmLink
    private let right: ArmLink
    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var reconnectCount: [UUID: Int] = [:]
    private var scanTimer: DispatchSourceTimer?
    private var upkeepTimer: DispatchSourceTimer?
    private var upkeepTicks = 0
    /// Distinguishes consecutive text messages on the display.
    private var textSeq: UInt8 = 0

    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let charWriteUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let charNotifyUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    public override init() {
        left = ArmLink(side: .left)
        right = ArmLink(side: .right)
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        left.attachOutbox(Self.makeOutbox(for: left))
        right.attachOutbox(Self.makeOutbox(for: right))
    }

    private static func makeOutbox(for arm: ArmLink) -> ArmOutbox {
        ArmOutbox(
            gap: writeGap,
            now: { ProcessInfo.processInfo.systemUptime },
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            },
            write: { [weak arm] data in arm?.writePlain(data) }
        )
    }

    private func arm(for side: G1Side) -> ArmLink { side == .left ? left : right }

    private func arm(for peripheral: CBPeripheral) -> ArmLink? {
        if left.peripheral == peripheral { return left }
        if right.peripheral == peripheral { return right }
        return nil
    }

    // MARK: - Scanning & Connection

    public func startScan(timeout: TimeInterval = 15) {
        guard central.state == .poweredOn else {
            state = .bluetoothOff
            lastError = .bluetoothUnavailable
            delegate?.glasses(self, didChangeState: state)
            return
        }
        state = .scanning
        scanResults.removeAll()
        pairs.removeAll()
        peripheralsById.removeAll()

        trace("Starting scan")

        // Peripherals the system already holds a link to do not advertise.
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        trace("Retrieved \(connected.count) connected peripherals")
        for p in connected {
            centralManager(central, didDiscover: p, advertisementData: [:], rssi: 0)
        }

        // Filtering by service UUID misses arms whose advertisement omits it,
        // so match on the name instead.
        central.scanForPeripherals(withServices: nil, options: nil)

        scanTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            trace("Scan timeout. Results: \(self.scanResults.count), pairs: \(self.pairs.count)")
            if self.isUsable {
                // Already talking to a pair; the timeout is just the scan
                // ending. Reporting an incomplete pair here is what put
                // «lentes incompletos» on screen next to a live link.
                trace("Scan timeout while connected: nothing to select")
            } else if self.scanResults.isEmpty && self.pairs.isEmpty {
                self.state = .idle
                self.lastError = .scanTimeout
                self.delegate?.glassesDidScanTimeout(self)
                self.delegate?.glasses(self, didChangeState: self.state)
            } else {
                self.delegate?.glasses(self, didRequirePairSelection: Array(self.pairs.values))
            }
        }
        scanTimer = timer
        timer.resume()
    }

    public func stopScan() {
        central.stopScan()
        scanTimer?.cancel()
        scanTimer = nil
        if case .scanning = state { state = .idle }
    }

    public func connect(pair: Pair) {
        trace("connect(pair) for channel \(pair.channel ?? "nil")")
        connectBy(leftId: pair.left?.id, rightId: pair.right?.id)
    }

    /// Connects to the first complete pair seen, or to whatever arms there are.
    public func connect() {
        if let complete = pairs.values.first(where: { $0.isComplete }) {
            trace("Connecting complete pair \(complete.channel ?? "unknown")")
            connect(pair: complete)
            return
        }
        let leftCand = scanResults.first(where: { $0.side == .left })
        let rightCand = scanResults.first(where: { $0.side == .right })
        if leftCand != nil || rightCand != nil {
            connectBy(leftId: leftCand?.id, rightId: rightCand?.id)
            return
        }
        trace("No candidates for auto-connect")
        delegate?.glasses(self, didRequirePairSelection: Array(pairs.values))
    }

    public func connectBy(leftId: UUID?, rightId: UUID?) {
        // Repeated scan results called this again while the first attempt was
        // still in flight, so every connect, restore and splash happened twice.
        if left.isLinkedOrLinking && right.isLinkedOrLinking {
            trace("connectBy ignored: already connected or connecting")
            return
        }
        state = .connecting
        for (id, arm) in [(leftId, left), (rightId, right)] {
            guard let id = id, let p = peripheralsById[id] else {
                trace("\(arm.side) peripheral id missing")
                continue
            }
            trace("Connecting \(arm.side): \(p.name ?? "Unknown")")
            arm.peripheral = p
            p.delegate = self
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
        delegate?.glasses(self, didChangeState: state)
    }

    public func disconnect() {
        for arm in [left, right] {
            if let p = arm.peripheral { central.cancelPeripheralConnection(p) }
        }
    }

    /// True once at least one arm can actually be written to.
    private var isUsable: Bool { left.isWritable || right.isWritable }

    // MARK: - Sending

    /// Left first, right `rightArmLag` after the left write actually went out.
    private func sendToBoth(_ data: Data?) {
        guard let data = data else { return }
        logCommand(data, prefix: "TX (Both)")
        if left.isWritable {
            left.enqueue(data) { [weak self] in
                guard let self = self else { return }
                self.right.enqueue(data, delay: Self.rightArmLag)
            }
        } else {
            trace("Left arm not writable; right only")
            right.enqueue(data, delay: Self.rightArmLag)
        }
    }

    private func send(_ data: Data?, to side: G1Side) {
        guard let data = data else { return }
        logCommand(data, prefix: "TX (\(side))")
        arm(for: side).enqueue(data)
    }

    // MARK: - Text

    /// Shows one page of text.
    ///
    /// The packet carries a single page and the firmware drops what does not
    /// fit; the caller decides the page boundaries. `page` and `pageCount`
    /// drive the pager the display draws.
    public func sendText(_ text: String, page: Int = 0, pageCount: Int = 1) {
        textSeq &+= 1
        sendToBoth(EvenG1Protocol.textData(
            text: text, seq: textSeq,
            page: UInt8(clamping: page), pageCount: UInt8(clamping: max(pageCount, 1))))
    }

    // MARK: - Images

    #if canImport(UIKit)
    /// Converts the image to the 576x136 1-bit buffer the display expects.
    public func sendImage(_ image: UIImage, completion: ((ImageTransferReport) -> Void)? = nil) {
        guard let raw = image.to1BitRaw(width: 576, height: 136) else { return }
        sendImage(raw: raw, completion: completion)
    }
    #endif

    /// Uploads a full-screen frame: every chunk, the end marker, then the CRC.
    public func sendImage(raw: Data, completion: ((ImageTransferReport) -> Void)? = nil) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let report = await self.sendImage(raw: raw)
            completion?(report)
        }
    }

    /// Uploads a full-screen frame and returns each arm's verdict.
    ///
    /// Nothing else goes out while this runs. The arms take the image as a
    /// byte stream and any other command written into the middle of it becomes
    /// part of the image: an 8-second keepalive landing inside a 3-second
    /// transfer is what made the left arm answer `0xCA` while the right, whose
    /// turn came after the beat had passed, answered `0xC9`. Both outboxes are
    /// paused for the duration and drain afterwards, in order.
    ///
    /// Image packets are written **with response**. An unresponded write is
    /// fire and forget: Core Bluetooth drops it when its buffer is full and
    /// says nothing, and the arms were receiving frames with holes in them.
    ///
    /// One arm at a time, because each keeps its own transfer state.
    @MainActor
    public func sendImage(raw: Data) async -> ImageTransferReport {
        // Sized against what both arms will actually take. A write larger
        // than the negotiated maximum is not truncated, it is dropped, and
        // nothing says so — the image simply fails its checksum at the far end.
        let room = [left, right]
            .compactMap { $0.peripheral?.maximumWriteValueLength(for: .withoutResponse) }
            .min() ?? EvenG1Protocol.Bmp.maxLength + 6
        let chunks = EvenG1Protocol.Bmp.data(
            image: raw, maxLength: max(16, min(EvenG1Protocol.Bmp.maxLength, room - 6)))
        trace("Image: \(chunks.count) chunks, arms take \(room) bytes per write")
        let endMarker = EvenG1Protocol.Bmp.endData()
        let crcPacket = EvenG1Protocol.Bmp.crcData(
            crcValue: crc32xz(of: EvenG1Protocol.Bmp.calculateCrcInput(image: raw)))

        isTransferringImage = true
        left.pause()
        right.pause()
        defer {
            isTransferringImage = false
            left.resume()
            right.resume()
        }

        var verdicts: [G1Side: Bool?] = [:]
        // Left first, as every other command goes. The order was tried both
        // ways on hardware and made no difference: which arm rejects is a
        // property of the arm, not of when its turn comes.
        for arm in [left, right] where arm.isWritable {
            var verdict: Bool? = nil
            for attempt in 1...Self.transferAttempts {
                var lost = 0
                for chunk in chunks where !(await arm.writeConfirmed(chunk, timeout: Self.writeTimeout)) {
                    lost += 1
                }
                if lost > 0 { trace("\(arm.side) lost \(lost) of \(chunks.count) chunks") }
                await arm.writeConfirmed(endMarker, timeout: Self.writeTimeout)
                verdict = await arm.writeAwaitingVerdict(
                    crcPacket, writeTimeout: Self.writeTimeout, verdictTimeout: Self.verdictTimeout)
                if verdict == true { break }
                trace("\(arm.side) rejected the frame on attempt \(attempt)")
            }
            verdicts[arm.side] = verdict
        }

        let report = ImageTransferReport(
            leftAccepted: verdicts[.left] ?? nil, rightAccepted: verdicts[.right] ?? nil)
        trace("Image transfer: left \(String(describing: report.leftAccepted)), "
              + "right \(String(describing: report.rightAccepted))")
        return report
    }

    public func hideImage() {
        sendToBoth(EvenG1Protocol.Bmp.hideData())
    }

    // MARK: - Upkeep
    //
    // The glasses do not push their own state. Without this the battery reading
    // is whatever it was at connect: it was showing an hour-old figure, and a
    // flat 0 on the left, because the query only ever went to the right arm.

    private func startUpkeep() {
        stopUpkeep()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.upkeepInterval, repeating: Self.upkeepInterval)
        timer.setEventHandler { [weak self] in self?.upkeepTick() }
        upkeepTimer = timer
        timer.resume()
    }

    private func stopUpkeep() {
        upkeepTimer?.cancel()
        upkeepTimer = nil
        upkeepTicks = 0
    }

    private func upkeepTick() {
        // Queued like anything else, so a beat raised mid-transfer waits its
        // turn instead of landing inside the frame.
        sendToBoth(EvenG1Protocol.heartbeatData())
        upkeepTicks &+= 1
        if upkeepTicks % Self.batteryEveryTicks == 0 { refreshBattery() }
    }

    /// Asks BOTH arms. Each one knows only its own charge, so querying one and
    /// reading the answer as a pair leaves the other at zero forever.
    public func refreshBattery() {
        sendToBoth(EvenG1Protocol.batteryData())
    }

    /// Everything the arms know about themselves. The outbox paces the
    /// queries; nothing here has to.
    public func refreshState() {
        send(EvenG1Protocol.getBrightnessData(), to: .right)
        refreshBattery()
        send(EvenG1Protocol.glassesStateData(), to: .right)
        send(EvenG1Protocol.getWearDetectionData(), to: .right)
        send(EvenG1Protocol.getDashPositionData(), to: .right)
        send(EvenG1Protocol.getStatusData(), to: .right)
        refreshDeviceInfo()
    }

    public func refreshDeviceInfo() {
        send(EvenG1Protocol.firmwareData(), to: .right)
        send(EvenG1Protocol.deviceSerialNumberData(), to: .right)
        send(EvenG1Protocol.getMacAddressData(), to: .right)
    }

    // MARK: - Settings

    public func setMicEnabled(_ enable: Bool) {
        send(EvenG1Protocol.micData(enable: enable), to: .right)
    }

    public func setSilentMode(enabled: Bool) {
        isSilentMode = enabled
        sendToBoth(EvenG1Protocol.silentModeData(enabled: enabled))
    }

    public func setWearDetection(enabled: Bool) {
        sendToBoth(EvenG1Protocol.wearDetectionData(enabled: enabled))
    }

    public func setBrightness(level: UInt8, auto: Bool) {
        brightnessLevel = Int(min(level, 42))
        sendToBoth(EvenG1Protocol.brightnessData(brightness: level, auto: auto))
    }

    public func setHeadTilt(angle: UInt8) {
        sendToBoth(EvenG1Protocol.headTiltData(angle: angle))
    }

    public func setHeadsUpMode(_ config: EvenG1Protocol.HeadsUpConfig) {
        sendToBoth(EvenG1Protocol.headsUpConfig(config))
    }

    public func setLanguage(_ language: EvenG1Protocol.Language) {
        sendToBoth(EvenG1Protocol.languageSetData(language))
    }

    public func startHeadUpCalibration() {
        sendToBoth(EvenG1Protocol.headUpCalibrationData(action: .start))
    }

    public func confirmHeadUpCalibration() {
        sendToBoth(EvenG1Protocol.headUpCalibrationData(action: .confirm))
    }

    public func exitHeadUpCalibration() {
        sendToBoth(EvenG1Protocol.headUpCalibrationData(action: .exit))
    }

    // MARK: - Dashboard

    public func sendDashboard(mode: EvenG1Protocol.DashMode, subMode: EvenG1Protocol.DashSubMode) {
        sendToBoth(EvenG1Protocol.dashModeData(mode: mode, subMode: subMode))
    }

    public func sendDashboardConfig(isShow: Bool, vertical: UInt8, distance: UInt8) {
        sendToBoth(EvenG1Protocol.dashData(isShow: isShow, vertical: vertical, distance: distance))
    }

    public func sendWeather(temperature: Int, icon: EvenG1Protocol.WeatherIcon, isCelsius: Bool) {
        sendToBoth(EvenG1Protocol.weatherData(temperature: temperature, icon: icon, isCelsius: isCelsius))
    }

    /// Sets the glasses' clock, and the weather beside it.
    ///
    /// The dashboard has no clock of its own: unless the phone tells it the
    /// time it keeps showing the start of its own epoch, which is what
    /// «monday 01-01, 01:00 am» is.
    public func syncTimeAndWeather(
        icon: EvenG1Protocol.WeatherIcon = .none,
        temperature: Int8 = 0,
        isFahrenheit: Bool = false,
        is12Hour: Bool = false
    ) {
        sendToBoth(EvenG1Protocol.dashTimeWeatherData(
            weatherIcon: icon, temp: temperature,
            isFahrenheit: isFahrenheit, is12Hour: is12Hour))
    }

    // MARK: - Notifications

    /// Shows a notification. Chunked JSON to the left arm, paced by its outbox
    /// — the caller's thread is never slept on.
    public func sendNotification(_ notification: EvenG1Notification, id: Int? = nil) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let payload = NotificationPayload(
            ncs_notification: NotificationPayload.NCSNotification(
                msg_id: id ?? Int(now.timeIntervalSince1970),
                type: 1,
                app_identifier: notification.appName,
                title: notification.title,
                subtitle: notification.subtitle,
                message: notification.message,
                time_s: Int(now.timeIntervalSince1970),
                date: formatter.string(from: now),
                display_name: notification.appName
            ),
            type: "ncs_notification"
        )
        guard let chunks = EvenG1Protocol.notificationData(payload) else { return }
        for chunk in chunks { send(chunk, to: .left) }
    }

    public func clearNotification(id: Int) {
        send(EvenG1Protocol.notificationClearData(msgId: id), to: .left)
    }

    // MARK: - Teleprompter & notes

    public func sendTeleprompter(visible: String, next: String, progress: UInt8, isFirst: Bool) {
        guard let packets = EvenG1Protocol.Teleprompter.data(
            isFirst: isFirst, visibleText: visible, nextText: next, completedPercent: progress)
        else { return }
        packets.forEach(sendToBoth)
    }

    public func exitTeleprompter() {
        sendToBoth(EvenG1Protocol.Teleprompter.endData())
    }

    public func sendQuickNote(title: String, content: String) {
        EvenG1Protocol.quickNoteData(title: title, content: content).forEach(sendToBoth)
    }

    public func sendNotes(_ notes: [EvenG1Protocol.Note]) {
        EvenG1Protocol.notesData(notes: notes).forEach(sendToBoth)
    }

    // MARK: - System & Admin

    public func reboot() {
        sendToBoth(EvenG1Protocol.rebootData())
    }

    public func factoryReset() {
        sendToBoth(EvenG1Protocol.factoryResetData())
    }

    public func setDebugLogging(enabled: Bool) {
        sendToBoth(EvenG1Protocol.debugLoggingData(enabled: enabled))
    }

    public func getMacAddress() {
        send(EvenG1Protocol.getMacAddressData(), to: .right)
    }

    // MARK: - Inbound

    private func handleIncoming(_ data: Data, from arm: ArmLink) {
        guard !data.isEmpty else { return }
        let event = G1Inbound.decode(data)
        trace("RX (\(arm.side)) [\(Self.commandName(data[0]))] \(Self.hex(data)) → \(event.traceDescription)")
        apply(event, from: arm)
        switch event {
        case .touch(let gesture): delegate?.glasses(self, didReceiveTouch: gesture, from: arm.side)
        case .micAudio(let audio): delegate?.glasses(self, didReceiveMicAudio: audio)
        default: break
        }
        delegate?.glasses(self, didReceive: event, from: arm.side)
    }

    /// Folds one event into the published state.
    private func apply(_ event: G1Inbound, from arm: ArmLink) {
        switch event {
        case .battery(let percent):
            batteryInfo = arm.side == .left
                ? EvenG1BatteryInfo(left: percent, right: batteryInfo.right, caseBattery: batteryInfo.caseBattery)
                : EvenG1BatteryInfo(left: batteryInfo.left, right: percent, caseBattery: batteryInfo.caseBattery)
        case .glassesState(let state):
            glassesState = state
        case .brightness(let level):
            brightnessLevel = level
        case .wearDetection(let enabled):
            wearDetectionEnabled = enabled
        case .dashPosition(let position):
            dashPosition = position
        case .touch(.tripleTap(let silent)):
            isSilentMode = silent
        case .imageVerdict(let accepted, _):
            arm.resolveVerdict(accepted)
        case .firmware(let version):
            firmwareVersion = version
        case .serial(let serial):
            serialNumber = serial
        case .macAddress(let mac):
            macAddress = mac
        case .touch, .imageEnd, .micAudio, .status, .unknown:
            break
        }
    }

    // MARK: - Trace helpers

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func commandName(_ opcode: UInt8) -> String {
        EvenG1Cmd(rawValue: opcode).map { "\($0)" } ?? "Unknown (0x\(String(format: "%02X", opcode)))"
    }

    private func logCommand(_ data: Data, prefix: String) {
        guard let opcode = data.first else { return }
        trace("\(prefix) [\(Self.commandName(opcode))] \(Self.hex(data))")
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate

extension EvenG1SDK: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            state = .bluetoothOff
            lastError = .bluetoothUnavailable
            delegate?.glasses(self, didChangeState: state)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover p: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        peripheralsById[p.identifier] = p
        let name = p.name ?? "Unknown"
        let (side, channel) = parseName(name)
        trace("Discovered \(name) -> side \(side), channel \(channel ?? "nil")")
        let d = Discovered(id: p.identifier, name: name, rssi: RSSI.intValue, side: side, channel: channel)

        if let idx = scanResults.firstIndex(where: { $0.id == d.id }) {
            scanResults[idx] = d
        } else {
            scanResults.append(d)
        }

        if let ch = channel {
            var pair = pairs[ch] ?? Pair(channel: ch, left: nil, right: nil)
            switch side {
            case .left: pair.left = d
            case .right: pair.right = d
            case .unknown: break
            }
            pairs[ch] = pair
        }

        delegate?.glasses(self, didUpdateScanResults: scanResults, pairs: Array(pairs.values))
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        trace("Connected to \(p.name ?? "Unknown")")
        p.delegate = self
        p.discoverServices([serviceUUID])
        checkConnectionState()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        trace("Failed to connect to \(p.name ?? "Unknown"): \(error?.localizedDescription ?? "no error")")
        let failure = G1Error.connectionFailed(name: p.name, id: p.identifier, underlying: error)
        lastError = failure
        delegate?.glasses(self, didFailToConnect: arm(for: p)?.side, name: p.name, error: error)
        state = .error(failure)
        delegate?.glasses(self, didChangeState: state)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        trace("Disconnected from \(p.name ?? "Unknown")")
        guard let arm = arm(for: p) else { return }
        delegate?.glasses(self, didLose: arm.side)
        arm.linkDropped()

        let attempt = (reconnectCount[p.identifier] ?? 0) + 1
        reconnectCount[p.identifier] = attempt
        if attempt <= Self.reconnectAttempts {
            delegate?.glasses(self, didBeginReconnectAttempt: attempt, side: arm.side)
            arm.peripheral = p
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        } else {
            checkConnectionState()
        }
    }

    private func checkConnectionState() {
        // A link you cannot write to is not a connection. `didConnect` fires
        // before service discovery, so an arm reports itself connected while
        // its write characteristic is still nil and everything sent to it is
        // dropped on the floor — which is why a splash sent the moment the
        // glasses "connected" only ever reached the arm that happened to
        // finish discovering first.
        let leftLinked = left.isLinked, rightLinked = right.isLinked
        let leftOk = left.isWritable, rightOk = right.isWritable
        trace("Connection state: left \(leftOk) (linked \(leftLinked)), right \(rightOk) (linked \(rightLinked))")

        if !leftLinked && !rightLinked {
            state = .idle
            stopUpkeep()
        } else if !leftOk && !rightOk {
            state = .connecting
        } else {
            state = .connected(left: leftOk, right: rightOk)
            if leftOk && rightOk { startUpkeep() }
        }
        delegate?.glasses(self, didChangeState: state)
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { trace("Write failed on \(arm(for: p)?.side.description ?? "?"): \(error.localizedDescription)") }
        arm(for: p)?.resolveWrite(error == nil)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        trace("Discovered services for \(p.name ?? "Unknown")")
        p.services?.forEach { p.discoverCharacteristics([charWriteUUID, charNotifyUUID], for: $0) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let arm = arm(for: p) else { return }
        trace("Discovered characteristics for \(arm.side)")
        s.characteristics?.forEach { ch in
            if ch.uuid == charWriteUUID {
                arm.writeChar = ch
            } else if ch.uuid == charNotifyUUID {
                p.setNotifyValue(true, for: ch)
                arm.notifyChar = ch
            }
        }
        if arm.isWritable {
            trace("\(arm.side) max write \(p.maximumWriteValueLength(for: .withoutResponse)) bytes "
                  + "(withResponse \(p.maximumWriteValueLength(for: .withResponse)))")
        }
        // The arm only becomes usable here, so this is where "connected" can
        // honestly be reported.
        checkConnectionState()
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let arm = arm(for: p) else { return }
        handleIncoming(data, from: arm)
    }
}

// MARK: - Helpers

extension EvenG1SDK {
    internal func parseName(_ name: String) -> (SideHint, String?) {
        let comps = name.split(separator: "_")
        guard comps.count >= 3 else { return (.unknown, nil) }
        let channel = String(comps[1])
        let sideStr = String(comps[2]).uppercased()
        let side: SideHint = (sideStr == "L") ? .left : (sideStr == "R" ? .right : .unknown)
        return (side, channel)
    }
}

/// Verbose BLE tracing. Off by default so the SDK stays quiet in a host app;
/// set `EvenG1SDK.isTracingEnabled = true` while debugging a connection.
public extension EvenG1SDK {
    static var isTracingEnabled = false

    /// Where trace lines go. Unset, they go to stderr.
    ///
    /// A host app on a physical device usually cannot read either stream —
    /// `print` block-buffers when stdout is not a terminal, and the console a
    /// device is launched with does not reliably carry it — so the app is left
    /// to decide, typically by appending to a file it can fetch afterwards.
    static var traceSink: ((String) -> Void)?
}

@inline(__always)
func trace(_ message: @autoclosure () -> String) {
    guard EvenG1SDK.isTracingEnabled else { return }
    let line = "[EvenG1Kit] \(message())"
    if let sink = EvenG1SDK.traceSink { sink(line) } else { fputs(line + "\n", stderr) }
}
