import Foundation

// MARK: - Public SDK Models

/// One temple of the glasses. Each is its own BLE peripheral, and a few
/// commands (the microphone, the state queries) are answered by one side only.
public enum G1Side: String, Sendable, CaseIterable, CustomStringConvertible {
    case left, right

    public var description: String { rawValue }
}

public struct EvenG1Notification: Sendable {
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

public enum EvenG1GlassesState: String, Equatable, Sendable {
    case wearing
    case off
    case caseOpen
    case caseClosed
    case unknown
}

public struct EvenG1BatteryInfo: Equatable, Sendable {
    public let left: Int
    public let right: Int
    public let caseBattery: Int?

    public init(left: Int, right: Int, caseBattery: Int?) {
        self.left = left
        self.right = right
        self.caseBattery = caseBattery
    }

    /// Nothing has answered yet. Both arms at zero is that, not a flat pair.
    public var isUnknown: Bool { left == 0 && right == 0 }
}

/// What the wearer did on a TouchBar, or what the arm volunteered about itself
/// on the same opcode (`0xF5`). Decoded from the sub-byte tables in PROTOCOL.md.
public enum G1Touch: Equatable, Sendable {
    /// Page forward in whatever is on the display.
    case singleTap
    /// Closes the current feature.
    case doubleTap
    /// Toggles silent mode on the glasses themselves. The payload carries the
    /// new state: ⚠️ which of `0x04`/`0x05` means *on* is inferred from the
    /// reference tables and has not been confirmed on a device.
    case tripleTap(silent: Bool)
    /// The bar is being held — the vendor's Even AI trigger.
    case longPressBegan
    case longPressEnded
    case dashboardShown
    case dashboardClosed
    /// A sub-byte the tables do not name.
    case other(UInt8)
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
