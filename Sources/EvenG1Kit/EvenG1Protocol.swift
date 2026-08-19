//
//  EvenG1Protocol.swift
//  EvenG1Kit
//
//  Created by Abraham Rubio on 21/09/25.
//

import Foundation

/// Command codes for the Even Realities G1 Protocol
public enum EvenG1Cmd: UInt8, CaseIterable {
    case error = 0x00
    case brightness = 0x01
    case silentMode = 0x03
    case addNotif = 0x04
    case dashMode = 0x06
    case headsUpConfig = 0x08
    case teleprompter = 0x09
    case navigate = 0x0A
    case headTilt = 0x0B
    case mic = 0x0E
    case bmp = 0x15 // File Upload
    case bmpShow = 0x16 // Bitmap Show
    case bmpHide = 0x18 // Bitmap Hide
    case notes = 0x1E
    case bmpComplete = 0x20 // File Upload Complete
    case firmwareInfo = 0x23
    case heartbeat = 0x25
    case dashConfig = 0x26
    case wearDetection = 0x27
    case brightnessState = 0x29
    case glassesState = 0x2B
    case battery = 0x2C
    case headsUp = 0x32
    case lensSerialNumber = 0x33
    case deviceSerialNumber = 0x34
    case uptime = 0x37
    case dashPosition = 0x3B
    case notification = 0x4B // Notification send
    case notificationClear = 0x4C // Notification Clear
    case ping = 0x4D
    case text = 0x4E
    case notifConfig = 0x4F
    case firmwareInfoRes = 0x6E
    case micData = 0xF1
    case device = 0xF5
    case notifSetting = 0xF6
    
    // Queries
    case statusGet = 0x22
    case wearDetectionGet = 0x3A
    
    // Display and media
    case timer = 0x07
    case transcribe = 0x0D
    case translate = 0x0F
    case headUpCalibration = 0x10
    case upgrade = 0x17
    case macAddress = 0x2D
    case language = 0x3D
    case unpair = 0x47
}

/// Helper structures and enums for G1 Commands
public struct EvenG1Protocol {
    
    // MARK: - Configuration
    
    public static func brightnessData(brightness: UInt8, auto: Bool) -> Data {
        let safeBrightness: UInt8 = brightness > 63 ? 63 : brightness
        return Data([EvenG1Cmd.brightness.rawValue, safeBrightness, auto ? 1 : 0])
    }
    
    public static func getBrightnessData() -> Data {
        return Data([EvenG1Cmd.brightnessState.rawValue])
    }
    
    public static func silentModeData(enabled: Bool) -> Data {
        // 0x0C enabled, 0x0A disabled
        return Data([EvenG1Cmd.silentMode.rawValue, enabled ? 0x0C : 0x0A, 0x00])
    }
    
    public static func wearDetectionData(enabled: Bool) -> Data {
        return Data([EvenG1Cmd.wearDetection.rawValue, enabled ? 0x01 : 0x00])
    }
    
    public static func getWearDetectionData() -> Data {
        return Data([EvenG1Cmd.wearDetectionGet.rawValue])
    }
    
    public static func getStatusData() -> Data {
        return Data([EvenG1Cmd.statusGet.rawValue])
    }
    
    // MARK: - Dashboard
    
    public enum DashMode: UInt8 {
        case full = 0x00
        case dual = 0x01
        case minimal = 0x02
    }
    
    public enum DashSubMode: UInt8 {
        case notes = 0x00
        case stock = 0x01
        case news = 0x02
        case calendar = 0x03
        case navigation = 0x04
        case map = 0x05
    }
    
    public enum DashModeConfig: UInt8 {
        case weatherTime = 0x01
        case calendar = 0x03
        case layout = 0x06
        case map = 0x07
    }
    
    // Sequence counter for dash mode commands (shared static state)
    static private var dashModeSeq: UInt8 = 0x00
    
    static private func dashModeGeneralData(_ config: DashModeConfig, _ data: [UInt8]) -> Data {
        let nullByte: UInt8 = 0x00
        let dataPayload: [UInt8] = [nullByte, dashModeSeq, config.rawValue] + data
        dashModeSeq &+= 1
        let length: UInt8 = UInt8(dataPayload.count + 2)
        return Data([EvenG1Cmd.dashMode.rawValue, length] + dataPayload)
    }
    
    public static func dashModeData(mode: DashMode, subMode: DashSubMode) -> Data {
        let subModeVal = (mode == .minimal) ? 0x00 : subMode.rawValue
        return dashModeGeneralData(.layout, [mode.rawValue, subModeVal])
    }
    
    public static func weatherData(temperature: Int, icon: WeatherIcon, isCelsius: Bool) -> Data {
        // 06 08 00 [temp] 02 [icon] [00/01]
        let tempByte = UInt8(bitPattern: Int8(temperature))
        let unitByte: UInt8 = isCelsius ? 0x00 : 0x01
        return Data([EvenG1Cmd.dashMode.rawValue, 0x08, 0x00, tempByte, 0x02, icon.rawValue, 0x00, unitByte])
    }
    
    public enum WeatherIcon: UInt8 {
        case none = 0x00
        case night = 0x01
        case clouds = 0x02
        case drizzle = 0x03
        case heavyDrizzle = 0x04
        case rain = 0x05
        case heavyRain = 0x06
        case thunder = 0x07
        case thunderStorm = 0x08
        case snow = 0x09
        case mist = 0x0A
        case fog = 0x0B
        case sand = 0x0C
        case squalls = 0x0D
        case tornado = 0x0E
        case freezing = 0x0F
        case sunny = 0x10
    }
    
    public static func dashTimeWeatherData(weatherIcon: WeatherIcon, temp: Int8, isFahrenheit: Bool = false, is12Hour: Bool = false) -> Data {
        let currentTime = Date().timeIntervalSince1970
        let epochTime32: [UInt8] = withUnsafeBytes(of: Int32(currentTime)) { Array($0) }
        let epochTime64: [UInt8] = withUnsafeBytes(of: Int64(currentTime * 1000)) { Array($0) }
        
        // Temperature travels as a raw byte, so negatives ride as two's complement.
        let tempByte = UInt8(bitPattern: temp)
        let fahrenheit: UInt8 = isFahrenheit ? 0x01 : 0x00
        let twelveHour: UInt8 = is12Hour ? 0x01 : 0x00
        
        return dashModeGeneralData(
            .weatherTime,
            epochTime32 + epochTime64 + [weatherIcon.rawValue, tempByte, fahrenheit, twelveHour]
        )
    }
    
    public static func dashData(isShow: Bool, vertical: UInt8, distance: UInt8) -> Data? {
        let cmd: UInt8 = 0x02
        let show: UInt8 = isShow ? 0x01 : 0x00
        guard vertical >= 1 && vertical <= 0x08 else { return nil }
        // distance is 1-5m in 0.5m increments (values 1-9)
        guard distance >= 1 && distance <= 0x09 else { return nil }
        
        // 0x26 08 00 01 02 show vert dist
        return Data([
            EvenG1Cmd.dashConfig.rawValue, 0x08, 0x00, 0x01,
            cmd, show, vertical, distance
        ])
    }
    
    public static func getDashPositionData() -> Data {
        return Data([EvenG1Cmd.dashPosition.rawValue])
    }
    
    // MARK: - Heads Up
    
    public enum HeadsUpConfig: UInt8 {
        case dashboard = 0x00
        case none = 0x02
    }
    
    public static func headsUpConfig(_ config: HeadsUpConfig) -> Data {
        // 0x08 06 00 00 03 config
        return Data([EvenG1Cmd.headsUpConfig.rawValue, 0x06, 0x00, 0x00, 0x03, config.rawValue])
    }
    
    public static func getHeadsUpConfig() -> Data {
        return Data([EvenG1Cmd.headsUpConfig.rawValue, 0x06, 0x00, 0x00, 0x04, 0x00])
    }
    
    public static func headTiltData(angle: UInt8) -> Data? {
        guard angle <= 60 else { return nil }
        return Data([EvenG1Cmd.headTilt.rawValue, angle, 0x01])
    }
    
    // MARK: - Notes
    
    public struct Note {
        public let title: String
        public let text: String
        
        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }
    
    static var noteId: UInt8 = 0x00
    
    public static func notesData(notes: [Note]) -> [Data] {
        return (0..<4).map { idx in
            noteId &+= 1
            let noteIdx: UInt8 = UInt8(idx + 1)
            if let note = notes[safe: idx] {
                let titleData: [UInt8] = Array(note.title.utf8)
                let titleLength: UInt8 = UInt8(titleData.count)
                let textData: [UInt8] = Array(note.text.utf8)
                let textLength: UInt8 = UInt8(textData.count)
                
                // 00 [id] 03 01 00 01 00 [idx] 01 [titleLen] [title] [textLen] 00 [text]
                let noteData: [UInt8] =
                    [0x00, noteId, 0x03, 0x01, 0x00, 0x01, 0x00, noteIdx, 0x01, titleLength] + titleData
                    + [textLength, 0x00] + textData
                
                let totalLength: UInt8 = UInt8(noteData.count + 2)
                return Data([EvenG1Cmd.notes.rawValue, totalLength] + noteData)
            } else {
                // Empty slot
                let noteData: [UInt8] = [
                    0x00, noteId, 0x03, 0x01, 0x00, 0x01, 0x00, noteIdx, 0x00,
                    0x01, 0x00, 0x01, 0x00, 0x00,
                ]
                let totalLength: UInt8 = UInt8(noteData.count + 2)
                return Data([EvenG1Cmd.notes.rawValue, totalLength] + noteData)
            }
        }
    }
    
    public static func quickNoteData(title: String, content: String) -> [Data] {
        // Legacy support: wrap in single note
        return notesData(notes: [Note(title: title, text: content)])
    }
    
    // MARK: - Text / Teleprompter
    
    public static func textData(text: String) -> Data? {
        guard let textData = text.data(using: .utf8) else { return nil }
        let cmd = EvenG1Cmd.text.rawValue
        let seq: UInt8 = 0x00
        let numItems: UInt8 = 0x01
        let item: UInt8 = 0x00
        let newScreen: UInt8 = 0x71 // 0x01 (new content) | 0x70 (text show)
        let newCharPos: [UInt8] = [0x00, 0x00]
        let pageNum: UInt8 = 0x00
        let pageCount: UInt8 = 0x01
        
        let controlArr = [cmd, seq, numItems, item, newScreen] + newCharPos + [pageNum, pageCount]
        return Data(controlArr) + textData
    }
    
    public struct Teleprompter {
        static private var seq: UInt8 = 0x00
        
        public static func data(isFirst: Bool, visibleText: String, nextText: String, completedPercent: UInt8) -> [Data]? {
            guard let visibleTextData = visibleText.data(using: .utf8),
                  let nextTextData = nextText.data(using: .utf8) else { return nil }
            
            let newScreen: UInt8 = isFirst ? 0x01 : 0x07
            let unknown1: UInt8 = isFirst ? 0x08 : 0x00
            let parts = [visibleTextData, nextTextData]
            
            return parts.enumerated().map { (index, part) in
                let partIdx: UInt8 = UInt8(index + 1)
                let numPackets: UInt8 = UInt8(parts.count)
                // 0x00, seq, newScreen, numPackets, 0x00, partIdx, 0x00, completedPercent, unknown1, 0x00
                let controlArr: [UInt8] = [
                    0x00, seq, newScreen, numPackets, 0x00, partIdx, 0x00, completedPercent, unknown1, 0x00
                ]
                seq &+= 1
                let len: UInt8 = UInt8(controlArr.count + part.count + 2)
                return Data([EvenG1Cmd.teleprompter.rawValue, len] + controlArr) + part
            }
        }
        
        public static func endData() -> Data {
            let cmd: UInt8 = 0x06
            let subCmd: UInt8 = 0x05
            let finish: UInt8 = 0x01
            // 0x09 06 00 seq 05 01
            return Data([EvenG1Cmd.teleprompter.rawValue, cmd, 0x00, seq, subCmd, finish])
        }
    }
    
    // MARK: - Device & Info
    
    public static func exitData() -> Data {
        return Data([EvenG1Cmd.bmpHide.rawValue])
    }
    
    public static func micData(enable: Bool) -> Data {
        return Data([EvenG1Cmd.mic.rawValue, enable ? 1 : 0])
    }
    
    public static func heartbeatData() -> Data {
        // 0x25 [length 06 00] [seq] 0x04. The firmware does not check the sequence
        // byte on keepalives, so it stays 0 and this builder needs no state.
        return Data([EvenG1Cmd.heartbeat.rawValue, 0x06, 0x00, 0x00, 0x04])
    }
    
    public static func batteryData() -> Data {
        return Data([EvenG1Cmd.battery.rawValue, 0x02])
    }
    
    public static func glassesStateData() -> Data {
        return Data([EvenG1Cmd.glassesState.rawValue])
    }
    
    public static func firmwareData() -> Data {
        return Data([EvenG1Cmd.firmwareInfo.rawValue, 0x74])
    }
    
    public static func lensSerialNumberData() -> Data {
        return Data([EvenG1Cmd.lensSerialNumber.rawValue])
    }
    
    public static func deviceSerialNumberData() -> Data {
        return Data([EvenG1Cmd.deviceSerialNumber.rawValue])
    }
    
    // MARK: - Notifications
    
    public struct Notification {
        public let msgId: Int
        public let title: String
        public let subtitle: String
        public let message: String
        public let displayName: String
        public let timeS: Int
        public let date: String
        
        public init(msgId: Int, title: String, subtitle: String, message: String, displayName: String) {
            self.msgId = msgId
            self.title = title
            self.subtitle = subtitle
            self.message = message
            self.displayName = displayName
            self.timeS = Int(Date().timeIntervalSince1970)
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            self.date = formatter.string(from: Date())
        }
        
        func toJSONData() -> Data? {
            let dict: [String: Any] = [
                "ncs_notification": [
                    "msg_id": msgId,
                    "type": 1, // Default type?
                    "app_identifier": "com.apple.mobile", // Generic
                    "title": title,
                    "subtitle": subtitle,
                    "message": message,
                    "time_s": timeS,
                    "date": date,
                    "display_name": displayName
                ],
                "type": "Add"
            ]
            return try? JSONSerialization.data(withJSONObject: dict, options: [])
        }
    }
    
    public static func notificationData(_ notification: NotificationPayload) -> [Data]? {
        guard let json = try? JSONEncoder().encode(notification) else { return nil }
        // 0x4B 0x00 [totalChunks] [chunkIndex] + JSON slice. The 4-byte header
        // has to fit inside the 180-byte payload limit alongside its chunk.
        let maxChunkSize = 176
        var chunks: [Data] = []
        let totalChunks = UInt8((json.count + maxChunkSize - 1) / maxChunkSize)
        
        var offset = 0
        var index: UInt8 = 0
        
        while offset < json.count {
            let length = min(maxChunkSize, json.count - offset)
            let chunkData = json.subdata(in: offset..<offset + length)
            
            let header = Data([EvenG1Cmd.notification.rawValue, 0x00, totalChunks, index])
            chunks.append(header + chunkData)
            
            offset += length
            index += 1
        }
        
        return chunks
    }
    
    public static func notificationClearData(msgId: Int) -> Data {
        // 0x4C + msg_id as a 4-byte big-endian integer.
        let idBytes = withUnsafeBytes(of: UInt32(msgId).bigEndian) { Array($0) }
        return Data([EvenG1Cmd.notificationClear.rawValue] + idBytes)
    }
    
    // MARK: - System & Debug
    
    public static func rebootData() -> Data {
        // 0x23 0x72
        return Data([EvenG1Cmd.firmwareInfo.rawValue, 0x72])
    }
    
    public static func debugLoggingData(enabled: Bool) -> Data {
        // 0x23 0x6C [00/01]
        return Data([EvenG1Cmd.firmwareInfo.rawValue, 0x6C, enabled ? 0x01 : 0x00])
    }
    
    public static func factoryResetData() -> Data {
        // Unpair command 0x47
        return Data([EvenG1Cmd.unpair.rawValue])
    }
    
    // MARK: - Info Getters
    
    public static func getMacAddressData() -> Data {
        return Data([EvenG1Cmd.macAddress.rawValue])
    }
    
    public static func getTimeSinceBootData() -> Data {
        return Data([EvenG1Cmd.uptime.rawValue])
    }
    
    // MARK: - Head Up Calibration
    
    public enum CalibrationAction: UInt8 {
        case start = 0x01
        case confirm = 0x02
        case exit = 0x03
    }
    
    public static func headUpCalibrationData(action: CalibrationAction) -> Data {
        return Data([EvenG1Cmd.headUpCalibration.rawValue, action.rawValue])
    }
    
    // MARK: - Language
    
    public enum Language: UInt8 {
        case english = 0x00
        case chinese = 0x01
        case japanese = 0x02
        case korean = 0x03
        case french = 0x04
        case german = 0x05
        case spanish = 0x06
        // Add others as known
    }
    
    public static func languageSetData(_ language: Language) -> Data {
        return Data([EvenG1Cmd.language.rawValue, language.rawValue])
    }
    
    // MARK: - Other Controls
    
    public static func translateControlData(enabled: Bool) -> Data {
        return Data([EvenG1Cmd.translate.rawValue, enabled ? 0x01 : 0x00])
    }
    
    public static func transcribeControlData(enabled: Bool) -> Data {
        return Data([EvenG1Cmd.transcribe.rawValue, enabled ? 0x01 : 0x00])
    }
    
    // MARK: - Images (BMP)
    
    public struct Bmp {
        static let maxLength = 194
        static let address: [UInt8] = [0x00, 0x1C, 0x00, 0x00]
        
        public static func data(image: Data) -> [Data] {
            let cmd = EvenG1Cmd.bmp.rawValue
            var chunks: [Data] = []
            var offset = 0
            var seq = 0
            
            while offset < image.count {
                let length = min(maxLength, image.count - offset)
                let chunkData = image.subdata(in: offset..<offset + length)
                
                let addressBytes: [UInt8] = (seq == 0) ? address : []
                let controlArr: [UInt8] = [cmd, UInt8(seq & 0xFF)] + addressBytes
                chunks.append(Data(controlArr) + chunkData)
                
                offset += length
                seq += 1
            }
            return chunks
        }
        
        /// End-of-transfer marker, sent once every chunk is out.
        public static func endData() -> Data {
            return Data([EvenG1Cmd.bmpComplete.rawValue, 0x0D, 0x0E])
        }
        
        public static func hideData() -> Data {
            return Data([EvenG1Cmd.bmpHide.rawValue])
        }
        
        /// Verification packet: 0x16 followed by the CRC-32/XZ in big-endian.
        public static func crcData(crcValue: UInt32) -> Data {
            let bytes = withUnsafeBytes(of: crcValue.bigEndian) { Array($0) }
            return Data([EvenG1Cmd.bmpShow.rawValue] + bytes)
        }
        
        public static func calculateCrcInput(image: Data) -> Data {
            return Data(address) + image
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
