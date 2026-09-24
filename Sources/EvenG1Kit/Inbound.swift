import Foundation

/// A packet the glasses sent, read into something a caller can switch on.
///
/// Pure: bytes in, a value out, no state touched. That is what lets the
/// readings that took six hardware sessions to get right — the brightness
/// readback at `data[2]` and not `data[1]`, the image verdict's status byte,
/// the wear state at byte 3 — be pinned by tests instead of by memory.
public enum G1Inbound: Equatable, Sendable {
    /// A TouchBar gesture, or a device event riding the same opcode.
    case touch(G1Touch)
    /// The arm's own charge. Each side reports only itself.
    case battery(percent: Int)
    /// Where the glasses are: on a face, off, or in the case.
    case glassesState(EvenG1GlassesState)
    /// The brightness level as the hardware has it, `0...42`.
    case brightness(level: Int)
    case wearDetection(enabled: Bool)
    case dashPosition(Int)
    /// The arm's verdict on the image just uploaded: the checksum it computed
    /// and whether it matched. This is the only report a display that cannot
    /// be seen from here ever gives.
    case imageVerdict(accepted: Bool, crc: UInt32)
    /// The arm took the end-of-image marker.
    case imageEnd(accepted: Bool)
    case micAudio(Data)
    case firmware(String)
    case serial(String)
    case macAddress(String)
    /// The response to `0x22`; its layout is not decoded.
    case status(Data)
    /// An opcode this decoder does not read.
    case unknown(opcode: UInt8)

    /// Reads one inbound packet.
    public static func decode(_ data: Data) -> G1Inbound {
        guard let opcode = data.first else { return .unknown(opcode: 0x00) }
        let bytes = [UInt8](data)
        guard let cmd = EvenG1Cmd(rawValue: opcode) else { return .unknown(opcode: opcode) }

        switch cmd {
        case .device:
            guard bytes.count >= 2 else { return .unknown(opcode: opcode) }
            return decodeDeviceEvent(sub: bytes[1], payload: Array(bytes.dropFirst(2)))

        case .micData:
            // 0xF1 [seq] [LC3 frames...]
            guard bytes.count > 2 else { return .unknown(opcode: opcode) }
            return .micAudio(data.subdata(in: 2..<data.count))

        case .battery:
            // 0x2C [frame type] [percent] ...
            guard bytes.count > 2 else { return .unknown(opcode: opcode) }
            return .battery(percent: Int(bytes[2]))

        case .glassesState:
            // 0x2B .. .. [state]
            guard bytes.count >= 4, let state = wearState(code: bytes[3]) else {
                return .unknown(opcode: opcode)
            }
            return .glassesState(state)

        case .brightnessState:
            // Observed on firmware 1.6.6: `29 65 2A`, where 0x2A is the level just
            // set and 0x65 is not it. Reading byte 1 reported 101 out of 42.
            guard bytes.count >= 3 else { return .unknown(opcode: opcode) }
            return .brightness(level: Int(bytes[2]))

        case .wearDetectionGet:
            guard bytes.count >= 2 else { return .unknown(opcode: opcode) }
            return .wearDetection(enabled: bytes[1] == 0x01)

        case .dashPosition:
            guard bytes.count >= 2 else { return .unknown(opcode: opcode) }
            return .dashPosition(Int(bytes[1]))

        case .bmpShow:
            // 16 [crc32 big-endian] [status]: 0xC9 intact, 0xCA not.
            guard bytes.count >= 6 else { return .imageVerdict(accepted: false, crc: 0) }
            let crc = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
            return .imageVerdict(accepted: bytes[5] == 0xC9, crc: crc)

        case .bmpComplete:
            // 20 C9 once the end marker is taken.
            return .imageEnd(accepted: bytes.count >= 2 && bytes[1] == 0xC9)

        case .firmwareInfoRes:
            return string(after: 1, in: data).map(G1Inbound.firmware) ?? .unknown(opcode: opcode)

        case .deviceSerialNumber:
            return string(after: 1, in: data).map(G1Inbound.serial) ?? .unknown(opcode: opcode)

        case .macAddress:
            guard bytes.count > 1 else { return .unknown(opcode: opcode) }
            let payload = data.subdata(in: 1..<data.count)
            if let text = String(data: payload, encoding: .utf8), text.contains(":") {
                return .macAddress(text)
            }
            return .macAddress(payload.map { String(format: "%02X", $0) }.joined(separator: ":"))

        case .statusGet:
            return .status(data)

        default:
            return .unknown(opcode: opcode)
        }
    }

    /// The `0xF5` sub-byte table. Gestures and device state share the opcode.
    private static func decodeDeviceEvent(sub: UInt8, payload: [UInt8]) -> G1Inbound {
        switch sub {
        case 0x01: return .touch(.singleTap)
        case 0x00, 0x20: return .touch(.doubleTap)
        case 0x04: return .touch(.tripleTap(silent: true))
        case 0x05: return .touch(.tripleTap(silent: false))
        case 0x17: return .touch(.longPressBegan)
        case 0x18, 0x16, 0x15: return .touch(.longPressEnded)
        case 0x1E: return .touch(.dashboardShown)
        case 0x1F: return .touch(.dashboardClosed)
        // The arms also volunteer their state on this opcode, with the same
        // codes the 0x2B query answers with. Reading them here is what lets
        // «puestos» follow the face instead of the last poll.
        case 0x06, 0x07, 0x08, 0x0B:
            return wearState(code: sub).map(G1Inbound.glassesState) ?? .touch(.other(sub))
        case 0x0A:
            guard let percent = payload.first else { return .touch(.other(sub)) }
            return .battery(percent: Int(percent))
        default: return .touch(.other(sub))
        }
    }

    private static func wearState(code: UInt8) -> EvenG1GlassesState? {
        switch code {
        case 0x06: return .wearing
        case 0x07: return .off
        case 0x08: return .caseOpen
        case 0x0B: return .caseClosed
        default: return nil
        }
    }

    private static func string(after offset: Int, in data: Data) -> String? {
        guard data.count > offset else { return nil }
        let text = String(decoding: data.subdata(in: offset..<data.count), as: UTF8.self)
        // Firmware strings arrive NUL-padded now and then; the padding is not text.
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One line for the trace, so a log reads as events and not as hex.
    public var traceDescription: String {
        switch self {
        case .touch(let gesture): return "Touch \(gesture)"
        case .battery(let percent): return "Battery \(percent)%"
        case .glassesState(let state): return "Glasses state \(state.rawValue)"
        case .brightness(let level): return "Brightness \(level)"
        case .wearDetection(let enabled): return "Wear detection \(enabled)"
        case .dashPosition(let position): return "Dash position \(position)"
        case .imageVerdict(let accepted, let crc):
            return "Image \(accepted ? "accepted" : "rejected") crc \(String(format: "%08X", crc))"
        case .imageEnd(let accepted): return "Image end \(accepted ? "taken" : "refused")"
        case .micAudio(let data): return "Mic audio \(data.count) bytes"
        case .firmware(let version): return "Firmware \(version)"
        case .serial(let serial): return "Serial \(serial)"
        case .macAddress(let mac): return "MAC \(mac)"
        case .status: return "Status"
        case .unknown(let opcode): return "Unknown 0x\(String(format: "%02X", opcode))"
        }
    }
}
