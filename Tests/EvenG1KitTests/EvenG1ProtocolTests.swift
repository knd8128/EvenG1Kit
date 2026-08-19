import XCTest
@testable import EvenG1Kit

final class EvenG1ProtocolTests: XCTestCase {

    func testBrightnessData() {
        let data = EvenG1Protocol.brightnessData(brightness: 10, auto: true)
        XCTAssertEqual(Array(data), [0x01, 10, 0x01])
    }

    func testSilentModeUsesDistinctFlags() {
        XCTAssertEqual(EvenG1Protocol.silentModeData(enabled: true)[1], 0x0C)
        XCTAssertEqual(EvenG1Protocol.silentModeData(enabled: false)[1], 0x0A)
    }

    func testDashModeCarriesLayoutAndSubMode() {
        let data = EvenG1Protocol.dashModeData(mode: .dual, subMode: .stock)
        // 0x06 [length] 0x00 [seq] [config] [layout] [subMode]
        XCTAssertEqual(data[0], EvenG1Cmd.dashMode.rawValue)
        XCTAssertEqual(data[1], UInt8(data.count))
        XCTAssertEqual(data[4], EvenG1Protocol.DashModeConfig.layout.rawValue)
        XCTAssertEqual(data[5], EvenG1Protocol.DashMode.dual.rawValue)
        XCTAssertEqual(data[6], EvenG1Protocol.DashSubMode.stock.rawValue)
    }

    func testMinimalLayoutForcesEmptySubMode() {
        let data = EvenG1Protocol.dashModeData(mode: .minimal, subMode: .stock)
        XCTAssertEqual(data[6], 0x00)
    }

    func testTextData() {
        let data = EvenG1Protocol.textData(text: "Hello")
        XCTAssertEqual(data?[0], EvenG1Cmd.text.rawValue)
        XCTAssertEqual(data?.suffix(5), Data("Hello".utf8))
    }

    // MARK: - Images

    func testBmpChunksCarryAddressOnFirstPacketOnly() {
        let image = Data(repeating: 0xAB, count: 500)
        let chunks = EvenG1Protocol.Bmp.data(image: image)

        XCTAssertEqual(chunks.count, 3) // 174 + 174 + 152
        XCTAssertEqual(Array(chunks[0].prefix(6)), [0x15, 0x00, 0x00, 0x1C, 0x00, 0x00])
        XCTAssertEqual(Array(chunks[1].prefix(2)), [0x15, 0x01])
        // Sizes are asserted against the firmware's packet limit, not a
        // literal, in testNoImagePacketExceedsWhatTheFirmwareTakes.

        let payload = chunks.enumerated().map { $0.offset == 0 ? $0.element.dropFirst(6) : $0.element.dropFirst(2) }
        XCTAssertEqual(Data(payload.joined()), image)
    }

    /// The end marker is 0x20, not the 0x16 that carries the checksum: sending
    /// 0x16 twice leaves the transfer unterminated.
    func testBmpEndMarkerIsDistinctFromCrcPacket() {
        XCTAssertEqual(Array(EvenG1Protocol.Bmp.endData()), [0x20, 0x0D, 0x0E])
        XCTAssertEqual(EvenG1Protocol.Bmp.crcData(crcValue: 0)[0], 0x16)
    }

    func testCrcIsComputedOverAddressPrefixedImage() {
        let image = Data(repeating: 0x01, count: 32)
        let input = EvenG1Protocol.Bmp.calculateCrcInput(image: image)
        XCTAssertEqual(Array(input.prefix(4)), [0x00, 0x1C, 0x00, 0x00])
        XCTAssertEqual(crc32xz(of: input), crc32xz(of: image, withPrefix: [0x00, 0x1C, 0x00, 0x00]))
    }

    func testCrc32XZMatchesKnownVector() {
        XCTAssertEqual(crc32xz(of: Data("123456789".utf8)), 0xCBF43926)
    }

    // MARK: - Notifications

    func testNotificationChunksFitThePayloadLimit() throws {
        let payload = NotificationPayload(
            ncs_notification: .init(
                msg_id: 1,
                type: 1,
                app_identifier: "com.example.app",
                title: "Title",
                subtitle: "Subtitle",
                message: String(repeating: "a", count: 600),
                time_s: 1_718_045_017,
                date: "2025-06-10 18:43:37",
                display_name: "Example"
            ),
            type: "ncs_notification"
        )
        let chunks = try XCTUnwrap(EvenG1Protocol.notificationData(payload))

        XCTAssertGreaterThan(chunks.count, 1)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.count, 180, "chunk exceeds the 180-byte MTU payload")
            XCTAssertEqual(Array(chunk.prefix(2)), [0x4B, 0x00])
            XCTAssertEqual(chunk[2], UInt8(chunks.count))
            XCTAssertEqual(chunk[3], UInt8(index))
        }
    }

    func testNotificationClearEncodesIdBigEndian() {
        XCTAssertEqual(Array(EvenG1Protocol.notificationClearData(msgId: 27)), [0x4C, 0x00, 0x00, 0x00, 0x1B])
    }

    func testHeartbeat() {
        XCTAssertEqual(Array(EvenG1Protocol.heartbeatData()), [0x25, 0x06, 0x00, 0x00, 0x04])
    }
}


extension EvenG1ProtocolTests {
    func testNoImagePacketExceedsWhatTheFirmwareTakes() {
        // 180 bytes per packet, and the first chunk also carries four address
        // bytes. Going over is silent: the packet simply never lands.
        let frame = Data(repeating: 0xA5, count: 576 * 136 / 8)
        let packets = EvenG1Protocol.Bmp.data(image: frame)
        for (index, packet) in packets.enumerated() {
            XCTAssertLessThanOrEqual(
                packet.count, 180,
                "chunk \(index) is \(packet.count) bytes, over the packet limit")
        }
    }

    func testEveryByteOfTheFrameIsSentExactlyOnce() {
        let frame = Data((0..<(576 * 136 / 8)).map { UInt8($0 % 251) })
        let packets = EvenG1Protocol.Bmp.data(image: frame)
        var rebuilt = Data()
        for (index, packet) in packets.enumerated() {
            // 0x15, seq, then four address bytes on the first chunk only.
            rebuilt.append(packet.dropFirst(index == 0 ? 6 : 2))
        }
        XCTAssertEqual(rebuilt, frame)
    }
}
