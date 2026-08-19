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

public protocol EvenG1Delegate: AnyObject {
    // Discovery / Selection
    func didUpdateScanResults(_ results: [EvenG1SDK.Discovered],
                              pairs: [EvenG1SDK.Pair])
    func didRequirePairSelection(_ pairs: [EvenG1SDK.Pair])
    
    // Connection State
    func didChangeConnectionState(_ state: EvenG1SDK.State)
    func didFailToConnect(name: String?, id: UUID, error: Error?)
    func didScanTimeout()
    
    // Reconnection / Loss
    func didBeginReconnectAttempt(count: Int, for id: UUID)
    func didLosePeripheral(name: String?, id: UUID)
    
    // Data / Events
    func didReceiveTouchEvent(side: String, type: String)
    func didReceiveMicAudio(data: Data)
    func didReceiveNotification(id: Int, title: String, subtitle: String, message: String, from: String)
    func didReceiveRawData(side: String, rawHex: String, decoded: String)
    
    // State
    func didUpdateBattery(left: Int, right: Int, caseBattery: Int?)
    func didUpdateGlassesState(_ state: EvenG1GlassesState)
}

// Optional delegate methods.
public extension EvenG1Delegate {
    func didUpdateBattery(left: Int, right: Int, caseBattery: Int?) {}
    func didUpdateGlassesState(_ state: EvenG1GlassesState) {}
}

public final class EvenG1SDK: NSObject, ObservableObject {
    public static let shared = EvenG1SDK()
    
    // MARK: - Public Types
    public enum State: Equatable {
        case idle
        case bluetoothOff
        case scanning
        case connecting
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
    }
    
    // MARK: - Public API observable
    @Published public private(set) var state: State = .idle
    @Published public private(set) var scanResults: [Discovered] = []
    @Published public private(set) var pairs: [String: Pair] = [:]
    @Published public private(set) var lastError: G1Error?
    
    // State tracking
    @Published public var batteryInfo: EvenG1BatteryInfo = EvenG1BatteryInfo(left: 0, right: 0, caseBattery: nil)
    @Published public var glassesState: EvenG1GlassesState = .unknown
    @Published public var brightness: Float? = nil
    /// Mirrors silent mode on the glasses: set by `setSilentMode(enabled:)` and
    /// updated when the wearer triple-taps the TouchBar.
    @Published public var isSilentMode: Bool = false
    @Published public var dashPosition: Int = 0
    @Published public var wearDetectionEnabled: Bool = true
    
    // Device Info
    @Published public var firmwareVersion: String = "Unknown"
    @Published public var serialNumber: String = "Unknown"
    @Published public var macAddress: String = "Unknown"
    
    public weak var delegate: EvenG1Delegate?
    
    // MARK: - BLE Internals
    private var central: CBCentralManager!
    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var reconnectCount: [UUID: Int] = [:]
    private var scanTimer: DispatchSourceTimer?
    
    private var leftPeripheral: CBPeripheral?
    private var rightPeripheral: CBPeripheral?
    
    // Characteristics
    private var leftWriteChar: CBCharacteristic?
    private var rightWriteChar: CBCharacteristic?
    private var leftNotifyChar: CBCharacteristic?
    private var rightNotifyChar: CBCharacteristic?
    
    // UUIDs
    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let charWriteUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let charNotifyUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    
    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Scanning & Connection
    
    public func startScan(timeout: TimeInterval = 15) {
        guard central.state == .poweredOn else {
            state = .bluetoothOff
            lastError = .bluetoothUnavailable
            delegate?.didChangeConnectionState(state)
            return
        }
        state = .scanning
        scanResults.removeAll()
        pairs.removeAll()
        peripheralsById.removeAll()
        
        trace("Starting Scan...")
        
        // 1. Retrieve already connected peripherals (System level)
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        trace("Retrieved \(connected.count) connected peripherals")
        for p in connected {
            trace("Found connected peripheral: \(p.name ?? "Unknown")")
            // Manually trigger discovery handling
            centralManager(central, didDiscover: p, advertisementData: [:], rssi: 0)
        }
        
        // 2. Scan for advertising peripherals. Filtering by service UUID misses
        // arms whose advertisement omits it, so match on the name instead.
        central.scanForPeripherals(withServices: nil, options: nil)
        
        scanTimer?.cancel()
        scanTimer = DispatchSource.makeTimerSource()
        scanTimer?.schedule(deadline: .now() + timeout)
        scanTimer?.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.central.stopScan()
                trace("Scan Timeout. Results: \(self.scanResults.count), Pairs: \(self.pairs.count)")
                if self.isUsable {
                    // Already talking to a pair; the timeout is just the scan
                    // ending. Reporting "incomplete pair" here is what put
                    // «lentes incompletos» on screen next to a live link.
                    trace("Scan timeout while connected -- nothing to select")
                } else if self.scanResults.isEmpty && self.pairs.isEmpty {
                    self.state = .idle
                    self.lastError = .scanTimeout
                    self.delegate?.didScanTimeout()
                    self.delegate?.didChangeConnectionState(self.state)
                } else {
                    self.delegate?.didRequirePairSelection(Array(self.pairs.values))
                }
            }
        }
        scanTimer?.resume()
    }
    
    public func stopScan() {
        central.stopScan()
        scanTimer?.cancel()
        scanTimer = nil
        if case .scanning = state { state = .idle }
    }
    
    public func connect(pair: Pair) {
        trace("connect(pair) called for channel: \(pair.channel ?? "nil")")
        connectBy(leftId: pair.left?.id, rightId: pair.right?.id)
    }
    
    public func connect() {
        trace("connect() called (Auto)")
        // Prefer complete pair
        if let complete = pairs.values.first(where: { $0.left != nil && $0.right != nil }) {
            trace("Found complete pair: \(complete.channel ?? "unknown")")
            connect(pair: complete); return
        }
        // Else first available L/R
        let leftCand  = scanResults.first(where: { $0.side == .left })
        let rightCand = scanResults.first(where: { $0.side == .right })
        
        trace("Candidates - Left: \(leftCand?.name ?? "nil"), Right: \(rightCand?.name ?? "nil")")
        
        if leftCand != nil || rightCand != nil {
            connectBy(leftId: leftCand?.id, rightId: rightCand?.id); return
        }
        trace("No candidates found for auto-connect")
        delegate?.didRequirePairSelection(Array(pairs.values))
    }
    
    public func connectBy(leftId: UUID?, rightId: UUID?) {
        // Repeated scan results called this again while the first attempt was
        // still in flight, so every connect, every restore and every frame
        // happened twice.
        if leftPeripheral?.state == .connected || leftPeripheral?.state == .connecting,
           rightPeripheral?.state == .connected || rightPeripheral?.state == .connecting {
            trace("connectBy ignored: already connected or connecting")
            return
        }
        trace("connectBy called. Left: \(String(describing: leftId)), Right: \(String(describing: rightId))")
        state = .connecting
        if let l = leftId, let p = peripheralsById[l] {
            trace("Connecting to Left Peripheral: \(p.name ?? "Unknown")")
            leftPeripheral = p
            p.delegate = self
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        } else {
            trace("Left Peripheral ID not found or nil")
        }
        if let r = rightId, let p = peripheralsById[r] {
            trace("Connecting to Right Peripheral: \(p.name ?? "Unknown")")
            rightPeripheral = p
            p.delegate = self
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        } else {
            trace("Right Peripheral ID not found or nil")
        }
        delegate?.didChangeConnectionState(state)
    }
    
    public func disconnect() {
        if let l = leftPeripheral { central.cancelPeripheralConnection(l) }
        if let r = rightPeripheral { central.cancelPeripheralConnection(r) }
    }
    
    // MARK: - Commands
    
    /// Gap between consecutive chunks of an image transfer. Fifty-one chunks
    /// make up one 576x136 frame, so this sets how long a frame takes to arrive.
    /// Called when an arm reports whether the image it just received is intact.
    private var imageVerdict: ((Bool) -> Void)?
    /// True while a frame is on the wire; nothing else may interleave with it.
    private var isTransferringImage = false
    /// Commands raised during a transfer, to be sent when it finishes.
    private var heldWrites: [Data] = []
    /// Image transfers pace themselves; not on the caller's thread.
    private let imageQueue = DispatchQueue(label: "network.rubio.eveng1.image")
    private var upkeepTimer: DispatchSourceTimer?
    private var upkeepTicks = 0

    private func sendToBoth(_ data: Data?) {
        guard let data = data else { return }
        // An image is a byte stream to the arms: a command written into the
        // middle of one becomes part of the image and fails its checksum.
        if isTransferringImage {
            trace("Held during image transfer: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            heldWrites.append(data)
            return
        }
        logCommand(data, prefix: "TX (Both)")
        
        // Send to Left
        if let l = leftPeripheral, let c = leftWriteChar {
            l.writeValue(data, for: c, type: .withoutResponse)
        } else {
            trace("Left Lens not ready (Peripheral: \(leftPeripheral != nil), Char: \(leftWriteChar != nil))")
        }
        
        // The right arm needs the gap; back-to-back writes drop on its side.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if let r = self.rightPeripheral, let c = self.rightWriteChar {
                r.writeValue(data, for: c, type: .withoutResponse)
            } else {
                trace("Right Lens not ready (Peripheral: \(self.rightPeripheral != nil), Char: \(self.rightWriteChar != nil))")
            }
        }
    }
    
    private func sendToRight(_ data: Data?) {
        guard let data = data, let r = rightPeripheral, let c = rightWriteChar else { return }
        logCommand(data, prefix: "TX (Right)")
        r.writeValue(data, for: c, type: .withoutResponse)
    }
    
    private func sendData(_ data: Data, to peripheral: CBPeripheral) {
        let char = (peripheral == leftPeripheral) ? leftWriteChar : rightWriteChar
        guard let c = char else { return }
        let side = (peripheral == leftPeripheral) ? "Left" : "Right"
        logCommand(data, prefix: "TX (\(side))")
        peripheral.writeValue(data, for: c, type: .withoutResponse)
    }
    
    /// Sends a single page of text. Content longer than one screen is truncated
    /// by the firmware; paginate upstream if the caller needs more.
    public func sendText(_ text: String) {
        sendToBoth(EvenG1Protocol.textData(text: text))
    }
    
    #if canImport(UIKit)
    /// Converts the image to the 576x136 1-bit buffer the display expects.
    public func sendImage(_ image: UIImage) {
        guard let raw = image.to1BitRaw(width: 576, height: 136) else { return }
        sendImage(raw: raw)
    }
    #endif
    
    /// What a transfer actually did.
    ///
    /// The verdict is not something to be inferred from chunk replies: this
    /// firmware does not answer the data packets at all. It answers the end
    /// marker with `0x20 0xC9`, and the CRC packet with the checksum it
    /// computed plus a status byte — `0xC9` if the image landed intact, `0xCA`
    /// if it did not. That status is the only truth available about a display
    /// that cannot be seen from here.
    public struct ImageTransferReport: Sendable {
        /// nil when the arm never answered at all.
        public let leftAccepted: Bool?
        public let rightAccepted: Bool?

        public var summary: String {
            "Izq. \(Self.word(leftAccepted)) · Der. \(Self.word(rightAccepted))"
        }

        private static func word(_ accepted: Bool?) -> String {
            switch accepted {
            case true?:  return "aceptada"
            case false?: return "rechazada"
            case nil:    return "sin respuesta"
            }
        }
    }

    /// Uploads a full-screen frame: every chunk, then the end marker, then the CRC.
    ///
    /// Nothing else may go out while this runs. The arms take the image as a
    /// byte stream and any other command written into the middle of it becomes
    /// part of the image: an 8-second keepalive landing inside a 3-second
    /// transfer is what made the left arm answer `0xCA` while the right, whose
    /// turn came after the beat had passed, answered `0xC9`. Other writes are
    /// held and sent afterwards.
    ///
    /// One arm at a time, because each keeps its own transfer state.
    public func sendImage(
        raw: Data, completion: ((ImageTransferReport) -> Void)? = nil
    ) {
        let chunks = EvenG1Protocol.Bmp.data(image: raw)
        let endMarker = EvenG1Protocol.Bmp.endData()
        let crcPacket = EvenG1Protocol.Bmp.crcData(
            crcValue: crc32xz(of: EvenG1Protocol.Bmp.calculateCrcInput(image: raw)))

        imageQueue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.sync { self.isTransferringImage = true }

            var verdicts: [Side: Bool] = [:]
            for side in [Side.left, Side.right] {
                for chunk in chunks {
                    self.writeDirectly(chunk, to: side)
                    Thread.sleep(forTimeInterval: Self.chunkGap)
                }
                self.writeDirectly(endMarker, to: side)
                Thread.sleep(forTimeInterval: Self.chunkGap)
                if let accepted = self.writeAwaitingVerdict(crcPacket, to: side) {
                    verdicts[side] = accepted
                }
            }

            let report = ImageTransferReport(
                leftAccepted: verdicts[.left], rightAccepted: verdicts[.right])
            trace("Image transfer: \(report.summary)")

            DispatchQueue.main.async {
                self.isTransferringImage = false
                self.flushHeldWrites()
                completion?(report)
            }
        }
    }

    enum Side { case left, right }

    /// Gap between image packets. The chunks are never acknowledged, so this is
    /// the pacing — not a timeout waiting for something that is coming.
    private static let chunkGap: TimeInterval = 0.06
    /// How long to wait for the arm's verdict on the CRC packet.
    private static let verdictTimeout: TimeInterval = 1.5

    private func writeDirectly(_ data: Data, to side: Side) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let peripheral = side == .left ? self.leftPeripheral : self.rightPeripheral
            guard let peripheral = peripheral,
                  let characteristic = self.writeChar(for: peripheral) else { return }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }

    /// Sends the CRC packet and waits for the arm to say whether the image
    /// arrived intact. Returns nil if it never answers.
    private func writeAwaitingVerdict(_ data: Data, to side: Side) -> Bool? {
        let semaphore = DispatchSemaphore(value: 0)
        let verdict = Locked<Bool?>(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { semaphore.signal(); return }
            self.imageVerdict = { accepted in
                verdict.value = accepted
                semaphore.signal()
            }
            self.writeDirectly(data, to: side)
        }
        _ = semaphore.wait(timeout: .now() + Self.verdictTimeout)
        DispatchQueue.main.async { [weak self] in self?.imageVerdict = nil }
        return verdict.value
    }

    /// Commands raised while an image was in flight, sent once it is done.
    private func flushHeldWrites() {
        let held = heldWrites
        heldWrites = []
        for (index, data) in held.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.12) {
                self.sendToBoth(data)
            }
        }
    }

    private func writeChar(for peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral == leftPeripheral ? leftWriteChar : rightWriteChar
    }

    // MARK: - Upkeep
    //
    // The glasses do not push their own state. Without this the battery reading
    // is whatever it was at connect: it was showing an hour-old figure, and a
    // flat 0 on the left, because the query only ever went to the right arm.

    /// Keepalive interval. Also the tick the other refreshes are counted in.
    private static let upkeepInterval: TimeInterval = 8
    /// Battery every twenty ticks; it does not move faster than that.
    private static let batteryEveryTicks = 20

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
        sendToBoth(EvenG1Protocol.heartbeatData())
        upkeepTicks &+= 1
        if upkeepTicks % Self.batteryEveryTicks == 0 { refreshBattery() }
    }

    /// Asks BOTH arms. Each one knows only its own charge, so querying one and
    /// reading the answer as a pair leaves the other at zero forever.
    public func refreshBattery() {
        sendToBoth(EvenG1Protocol.batteryData())
    }

    /// Sets the glasses' clock, and the weather beside it.
    ///
    /// The dashboard has no clock of its own: unless the phone tells it the
    /// time it will keep showing the start of its own epoch, which is what
    /// "monday 01-01, 01:00 am" is.
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

    public func refreshState() {
        // Staggered so the glasses are not flooded with back-to-back queries.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendToRight(EvenG1Protocol.getBrightnessData())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // Both: each arm reports only its own charge.
            self.sendToBoth(EvenG1Protocol.batteryData())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            self.sendToRight(EvenG1Protocol.glassesStateData())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            self.sendToRight(EvenG1Protocol.getWearDetectionData())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            self.sendToRight(EvenG1Protocol.getDashPositionData())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.sendToRight(EvenG1Protocol.getStatusData())
        }
        
        // Refresh Device Info
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.refreshDeviceInfo()
        }
    }
    
    public func refreshDeviceInfo() {
        sendToRight(EvenG1Protocol.firmwareData())
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.sendToRight(EvenG1Protocol.deviceSerialNumberData())
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.sendToRight(EvenG1Protocol.getMacAddressData())
        }
    }
    
    public func hideImage() {
        sendToBoth(EvenG1Protocol.Bmp.hideData())
    }
    
    public func setMicEnabled(_ enable: Bool) {
        sendToRight(EvenG1Protocol.micData(enable: enable))
    }
    
    public func sendSilentMode(enabled: Bool) {
        sendToBoth(EvenG1Protocol.silentModeData(enabled: enabled))
    }
    
    public func setSilentMode(enabled: Bool) {
        sendToBoth(EvenG1Protocol.silentModeData(enabled: enabled))
    }
    
    public func setWearDetection(enabled: Bool) {
        sendToBoth(EvenG1Protocol.wearDetectionData(enabled: enabled))
    }
    
    public func setBrightness(level: UInt8, auto: Bool) {
        // Optimistic update
        let maxLevel: Float = 42.0
        let normalized = min(max(Float(level) / maxLevel, 0.0), 1.0)
        self.brightness = normalized
        
        sendToBoth(EvenG1Protocol.brightnessData(brightness: level, auto: auto))
    }
    
    public func sendDashboard(mode: EvenG1Protocol.DashMode, subMode: EvenG1Protocol.DashSubMode) {
        sendToBoth(EvenG1Protocol.dashModeData(mode: mode, subMode: subMode))
    }
    
    public func sendDashboardConfig(isShow: Bool, vertical: UInt8, distance: UInt8) {
        sendToBoth(EvenG1Protocol.dashData(isShow: isShow, vertical: vertical, distance: distance))
    }
    
    public func sendWeather(temperature: Int, icon: EvenG1Protocol.WeatherIcon, isCelsius: Bool) {
        sendToBoth(EvenG1Protocol.weatherData(temperature: temperature, icon: icon, isCelsius: isCelsius))
    }
    
    public func sendNotification(_ notification: EvenG1Notification) {
        // Convert public model to internal payload
        let payload = NotificationPayload(
            ncs_notification: NotificationPayload.NCSNotification(
                msg_id: Int(Date().timeIntervalSince1970), // Simple ID generation
                type: 1, // Unknown type, maybe 1 is standard?
                app_identifier: notification.appName,
                title: notification.title,
                subtitle: notification.subtitle,
                message: notification.message,
                time_s: Int(Date().timeIntervalSince1970),
                date: Date().formatted(), // Needs specific format? Wiki example: "2025-06-10 18:43:37"
                display_name: notification.appName
            ),
            type: "ncs_notification"
        )
        
        if let chunks = EvenG1Protocol.notificationData(payload) {
            for chunk in chunks {
                // Notifications go to the left arm only.
                if let left = leftPeripheral {
                    sendData(chunk, to: left)
                    // The glasses acknowledge each chunk with 0xC9; pacing the
                    // writes stands in for waiting on that response.
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }
    
    public func clearNotification(id: Int) {
        if let left = leftPeripheral {
            sendData(EvenG1Protocol.notificationClearData(msgId: id), to: left)
        }
    }
    
    public func sendTeleprompter(visible: String, next: String, progress: UInt8, isFirst: Bool) {
        guard let packets = EvenG1Protocol.Teleprompter.data(isFirst: isFirst, visibleText: visible, nextText: next, completedPercent: progress) else { return }
        for packet in packets {
            sendToBoth(packet)
        }
    }
    
    public func exitTeleprompter() {
        sendToBoth(EvenG1Protocol.Teleprompter.endData())
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
        sendToRight(EvenG1Protocol.getMacAddressData())
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
    
    public func setHeadsUpMode(_ config: EvenG1Protocol.HeadsUpConfig) {
        sendToBoth(EvenG1Protocol.headsUpConfig(config))
    }
    
    public func setHeadTilt(angle: UInt8) {
        guard let data = EvenG1Protocol.headTiltData(angle: angle) else { return }
        sendToBoth(data)
    }
    
    public func sendQuickNote(title: String, content: String) {
        let packets = EvenG1Protocol.quickNoteData(title: title, content: content)
        for packet in packets {
            sendToBoth(packet)
        }
    }
    
    public func sendNotes(_ notes: [EvenG1Protocol.Note]) {
        let packets = EvenG1Protocol.notesData(notes: notes)
        for packet in packets {
            sendToBoth(packet)
        }
    }
    
    // MARK: - Incoming Data Handling
    
    private func handleIncomingData(_ data: Data, side: String) {
        logCommand(data, prefix: "RX (\(side))")
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        // Decoded form is for the log stream; parsing below drives state.
        var decoded = "Unknown"
        
        guard !data.isEmpty else { return }
        let cmdByte = data[0]
        
        if let cmd = EvenG1Cmd(rawValue: cmdByte) {
            switch cmd {
            case .device: // 0xF5
                if data.count >= 2 {
                    let sub = data[1]
                    switch sub {
                    case 0x01: decoded = "Single Tap"
                    case 0x00: decoded = "Double Tap"
                    // Triple tap toggles silent mode on the glasses themselves, so
                    // the published flag has to follow the hardware, not just our
                    // own writes. Which of the two codes means "on" is inferred from
                    // the reference tables and has not been confirmed on a device.
                    case 0x04, 0x05:
                        let silent = sub == 0x04
                        decoded = "Triple Tap (silent \(silent ? "on" : "off"))"
                        DispatchQueue.main.async { self.isSilentMode = silent }
                    // 0x17 fires while the bar is held (Even AI starts capturing),
                    // 0x18 when it is released.
                    case 0x17: decoded = "Long Press Start"
                    case 0x18: decoded = "Long Press End"
                    case 0x16, 0x15: decoded = "Long Press End"
                    default: decoded = "Touch Event 0x\(String(format: "%02X", sub))"
                    }
                    delegate?.didReceiveTouchEvent(side: side, type: decoded)
                }
            case .micData: // 0xF1
                if data.count > 2 {
                    decoded = "Mic Audio"
                    delegate?.didReceiveMicAudio(data: data.subdata(in: 2..<data.count))
                }
            case .battery: // 0x2C
                // Parse battery
                // Left: 0x2c 66 4b ...
                // Right: 0x2c 66 4d ...
                if data.count > 2 {
                    let val = Int(data[2])
                    decoded = "Battery: \(val)%"
                    var current = batteryInfo
                    if side == "LEFT" {
                        current = EvenG1BatteryInfo(left: val, right: current.right, caseBattery: current.caseBattery)
                    } else {
                        current = EvenG1BatteryInfo(left: current.left, right: val, caseBattery: current.caseBattery)
                    }
                    batteryInfo = current
                    delegate?.didUpdateBattery(left: batteryInfo.left, right: batteryInfo.right, caseBattery: batteryInfo.caseBattery)
                }
            case .glassesState: // 0x2B
                if data.count >= 4 {
                    let stateByte = data[3]
                    var newState: EvenG1GlassesState = .unknown
                    switch stateByte {
                    case 0x06: newState = .wearing
                    case 0x07: newState = .off
                    case 0x08: newState = .caseOpen
                    case 0x0B: newState = .caseClosed
                    default: break
                    }
                    decoded = "Glasses State: \(newState)"
                    if newState != .unknown {
                        glassesState = newState
                        delegate?.didUpdateGlassesState(newState)
                    }
                }
            case .brightnessState: // 0x29
                // Observed on firmware 1.6.6: 29 65 2A, where 0x2A is the level
                // that was just set and 0x65 is not it. Reading data[1] as the
                // level reported 101 out of 42 and pinned the readback at full.
                if data.count >= 3 {
                    let level = Float(data[2])
                    let maxLevel: Float = 42.0
                    let normalized = min(max(level / maxLevel, 0.0), 1.0)
                    DispatchQueue.main.async {
                        self.brightness = normalized
                    }
                    decoded = "Brightness: \(Int(level))"
                }
            case .wearDetectionGet: // 0x3A
                if data.count >= 2 {
                    let enabled = data[1] == 0x01
                    DispatchQueue.main.async {
                        self.wearDetectionEnabled = enabled
                    }
                    decoded = "Wear Detection: \(enabled)"
                }
            case .dashPosition: // 0x3B
                if data.count >= 2 {
                    let pos = Int(data[1])
                    DispatchQueue.main.async {
                        self.dashPosition = pos
                    }
                    decoded = "Dash Position: \(pos)"
                }
            case .statusGet: // 0x22
                decoded = "Status: \(hex)"
            case .bmpShow: // 0x16 — the arm's verdict on the image just sent
                // 16 [crc32 big-endian] [status], where 0xC9 means the image
                // arrived intact and 0xCA means it did not.
                let accepted = data.count >= 6 && data[5] == 0xC9
                decoded = accepted ? "Image accepted" : "Image rejected: \(hex)"
                imageVerdict?(accepted)
                imageVerdict = nil
            case .notification: // 0x4B
                decoded = "Notification RX"
            case .firmwareInfoRes: // 0x6E
                if data.count > 1 {
                    let versionData = data.subdata(in: 1..<data.count)
                    if let versionStr = String(data: versionData, encoding: .utf8) {
                        decoded = "Firmware: \(versionStr)"
                        DispatchQueue.main.async {
                            self.firmwareVersion = versionStr
                        }
                    }
                }
            case .deviceSerialNumber: // 0x34
                if data.count > 1 {
                    let snData = data.subdata(in: 1..<data.count)
                    if let snStr = String(data: snData, encoding: .utf8) {
                        decoded = "Serial: \(snStr)"
                        DispatchQueue.main.async {
                            self.serialNumber = snStr
                        }
                    }
                }
            case .macAddress: // 0x2D
                if data.count > 1 {
                    let macData = data.subdata(in: 1..<data.count)
                    // MAC is likely a string or bytes. Try string first.
                    if let macStr = String(data: macData, encoding: .utf8), macStr.contains(":") {
                         decoded = "MAC: \(macStr)"
                         DispatchQueue.main.async {
                             self.macAddress = macStr
                         }
                    } else {
                        // Fallback to hex bytes
                        let macHex = macData.map { String(format: "%02X", $0) }.joined(separator: ":")
                        decoded = "MAC: \(macHex)"
                        DispatchQueue.main.async {
                            self.macAddress = macHex
                        }
                    }
                }
            default:
                decoded = "Cmd \(cmd)"
            }
        }
        
        delegate?.didReceiveRawData(side: side, rawHex: hex, decoded: decoded)
    }
}

// MARK: - CBCentralManagerDelegate
extension EvenG1SDK: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            state = .bluetoothOff
            lastError = .bluetoothUnavailable
            delegate?.didChangeConnectionState(state)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        peripheralsById[p.identifier] = p
        let name = p.name ?? "Unknown"
        let (side, channel) = parseName(name)
        trace("Discovered \(name) -> Side: \(side), Channel: \(channel ?? "nil")")
        let d = Discovered(id: p.identifier, name: name, rssi: RSSI.intValue, side: side, channel: channel)
        
        if let idx = scanResults.firstIndex(where: { $0.id == d.id }) {
            scanResults[idx] = d
        } else {
            scanResults.append(d)
        }
        
        if let ch = channel {
            var pair = pairs[ch] ?? Pair(channel: ch, left: nil, right: nil)
            switch side {
            case .left:  pair.left  = d
            case .right: pair.right = d
            case .unknown: break
            }
            pairs[ch] = pair
        }
        
        delegate?.didUpdateScanResults(scanResults, pairs: Array(pairs.values))
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        trace("Connected to \(p.name ?? "Unknown")")
        p.delegate = self
        p.discoverServices([serviceUUID])
        checkConnectionState()
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        trace("Failed to connect to \(p.name ?? "Unknown"): \(error?.localizedDescription ?? "No error")")
        lastError = .connectionFailed(name: p.name, id: p.identifier, underlying: error)
        delegate?.didFailToConnect(name: p.name, id: p.identifier, error: error)
        state = .error(lastError!)
        delegate?.didChangeConnectionState(state)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        trace("Disconnected from \(p.name ?? "Unknown")")
        delegate?.didLosePeripheral(name: p.name, id: p.identifier)
        
        if p == leftPeripheral { leftPeripheral = nil; leftWriteChar = nil; leftNotifyChar = nil }
        if p == rightPeripheral { rightPeripheral = nil; rightWriteChar = nil; rightNotifyChar = nil }
        
        // Simple reconnect logic
        let c = (reconnectCount[p.identifier] ?? 0) + 1
        reconnectCount[p.identifier] = c
        if c <= 3 {
            delegate?.didBeginReconnectAttempt(count: c, for: p.identifier)
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        } else {
            checkConnectionState()
        }
    }
    
    private func checkConnectionState() {
        let leftLinked = (leftPeripheral?.state == .connected)
        let rightLinked = (rightPeripheral?.state == .connected)
        // A link you cannot write to is not a connection. `didConnect` fires
        // before service discovery, so an arm reports itself connected while
        // its write characteristic is still nil and everything sent to it is
        // dropped on the floor -- which is why a splash sent the moment the
        // glasses "connected" only ever reached the arm that happened to
        // finish discovering first.
        let leftOk = leftLinked && leftWriteChar != nil
        let rightOk = rightLinked && rightWriteChar != nil
        trace("Connection State Check - Left: \(leftOk) (linked \(leftLinked)), "
              + "Right: \(rightOk) (linked \(rightLinked))")

        if !leftLinked && !rightLinked {
            state = .idle
            stopUpkeep()
            imageVerdict = nil
            isTransferringImage = false
            heldWrites = []
        } else if !leftOk && !rightOk {
            state = .connecting
        } else {
            state = .connected(left: leftOk, right: rightOk)
            if leftOk && rightOk { startUpkeep() }
        }
        delegate?.didChangeConnectionState(state)
    }

    /// True once at least one arm can actually be written to.
    private var isUsable: Bool { leftWriteChar != nil || rightWriteChar != nil }
    
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        trace("Discovered Services for \(p.name ?? "Unknown")")
        p.services?.forEach { p.discoverCharacteristics([charWriteUUID, charNotifyUUID], for: $0) }
    }
    
    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        trace("Discovered Characteristics for \(p.name ?? "Unknown")")
        s.characteristics?.forEach { ch in
            if ch.uuid == charWriteUUID {
                if p == leftPeripheral {
                    trace("Found Left Write Char")
                    leftWriteChar = ch
                }
                if p == rightPeripheral {
                    trace("Found Right Write Char")
                    rightWriteChar = ch
                }
            } else if ch.uuid == charNotifyUUID {
                p.setNotifyValue(true, for: ch)
                if p == leftPeripheral {
                    trace("Found Left Notify Char")
                    leftNotifyChar = ch
                }
                if p == rightPeripheral {
                    trace("Found Right Notify Char")
                    rightNotifyChar = ch
                }
            }
        }
        // The arm only becomes usable here, so this is where "connected" can
        // honestly be reported.
        checkConnectionState()
    }
    
    public func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let side = (p == leftPeripheral) ? "LEFT" : "RIGHT"
        handleIncomingData(data, side: side)
    }


    // MARK: - Logging Helper
    
    private func logCommand(_ data: Data, prefix: String) {
        guard !data.isEmpty else { return }
        let cmdByte = data[0]
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        var cmdName = "Unknown (0x\(String(format: "%02X", cmdByte)))"
        if let cmd = EvenG1Cmd(rawValue: cmdByte) {
            cmdName = "\(cmd)"
        }
        
        trace("\(prefix) [\(cmdName)] Data: \(hex)")
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


/// One value, guarded, so a result can cross the queue the semaphore separates.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
