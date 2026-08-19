import Foundation

// MARK: - Public SDK Models

public struct EvenG1Notification {
    public let title: String
    public let subtitle: String
    public let message: String
    public let appName: String
    
    public init(title: String, subtitle: String, message: String, appName: String) {
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.appName = appName
    }
}

public enum EvenG1GlassesState: String, Equatable {
    case wearing
    case off
    case caseOpen
    case caseClosed
    case unknown
}

public struct EvenG1BatteryInfo: Equatable {
    public let left: Int
    public let right: Int
    public let caseBattery: Int?
    
    public init(left: Int, right: Int, caseBattery: Int?) {
        self.left = left
        self.right = right
        self.caseBattery = caseBattery
    }
}

// MARK: - Internal / Protocol Models

public struct NotificationPayload: Codable {
    public struct NCSNotification: Codable {
        public let msg_id: Int
        public let type: Int
        public let app_identifier: String
        public let title: String
        public let subtitle: String
        public let message: String
        public let time_s: Int
        public let date: String
        public let display_name: String
    }
    public let ncs_notification: NCSNotification
    public let type: String
}

public enum G1TextMode: UInt8 {
    /// Text Show (basic text mode)
    case textShow = 0x70
    /// Even AI automatic
    case aiAuto   = 0x30
    /// Even AI manual (controlled by taps)
    case aiManual = 0x50
    /// Even AI complete
    case aiComplete = 0x40
    /// Even AI network error
    case aiNetworkError = 0x60
}

public enum G1Error: Error, CustomStringConvertible, Equatable {
    case bluetoothUnavailable
    case scanTimeout
    case connectionFailed(name: String?, id: UUID, underlying: Error?)
    case servicesNotFound
    case characteristicsNotFound
    case disconnected
    
    public static func == (lhs: G1Error, rhs: G1Error) -> Bool {
        switch (lhs, rhs) {
        case (.bluetoothUnavailable, .bluetoothUnavailable),
             (.scanTimeout, .scanTimeout),
             (.servicesNotFound, .servicesNotFound),
             (.characteristicsNotFound, .characteristicsNotFound),
             (.disconnected, .disconnected):
            return true
        case let (.connectionFailed(ln, lid, _), .connectionFailed(rn, rid, _)):
            return ln == rn && lid == rid
        default:
            return false
        }
    }
    
    public var description: String {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .scanTimeout: return "Scan timeout"
        case .connectionFailed(let n, let id, let e):
            return "Connection failed \(n ?? "device") \(id.uuidString) \(e?.localizedDescription ?? "")"
        case .servicesNotFound: return "UART service not found"
        case .characteristicsNotFound: return "UART characteristics not found"
        case .disconnected: return "Device disconnected"
        }
    }
}
