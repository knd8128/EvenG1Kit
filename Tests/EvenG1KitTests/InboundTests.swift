import XCTest
@testable import EvenG1Kit

/// The readings that took six hardware sessions to get right, pinned.
final class InboundTests: XCTestCase {

    func testBrightnessReadbackIsByteTwoNotByteOne() {
        // Observed on firmware 1.6.6 after setting 0x2A: `29 65 2A`. Reading
        // byte 1 reported 101 out of 42.
        XCTAssertEqual(G1Inbound.decode(Data([0x29, 0x65, 0x2A])), .brightness(level: 42))
    }

    func testBatteryPercentIsByteTwo() {
        XCTAssertEqual(G1Inbound.decode(Data([0x2C, 0x66, 0x4B, 0x00])), .battery(percent: 75))
    }

    func testImageVerdictReadsStatusByteAndChecksum() {
        let accepted = G1Inbound.decode(Data([0x16, 0xD4, 0x97, 0x3E, 0xE7, 0xC9]))
        XCTAssertEqual(accepted, .imageVerdict(accepted: true, crc: 0xD497_3EE7))
        let rejected = G1Inbound.decode(Data([0x16, 0xD4, 0x97, 0x3E, 0xE7, 0xCA]))
        XCTAssertEqual(rejected, .imageVerdict(accepted: false, crc: 0xD497_3EE7))
    }

    func testImageEndMarkerAck() {
        XCTAssertEqual(G1Inbound.decode(Data([0x20, 0xC9])), .imageEnd(accepted: true))
        XCTAssertEqual(G1Inbound.decode(Data([0x20, 0xCA])), .imageEnd(accepted: false))
    }

    func testGlassesStateIsByteThree() {
        XCTAssertEqual(G1Inbound.decode(Data([0x2B, 0x00, 0x00, 0x06])), .glassesState(.wearing))
        XCTAssertEqual(G1Inbound.decode(Data([0x2B, 0x00, 0x00, 0x0B])), .glassesState(.caseClosed))
        // A code the table does not name is not a state.
        XCTAssertEqual(G1Inbound.decode(Data([0x2B, 0x00, 0x00, 0x42])), .unknown(opcode: 0x2B))
    }

    func testTouchGestures() {
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x01])), .touch(.singleTap))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x00])), .touch(.doubleTap))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x04])), .touch(.tripleTap(silent: true)))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x05])), .touch(.tripleTap(silent: false)))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x17])), .touch(.longPressBegan))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x18])), .touch(.longPressEnded))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x7E])), .touch(.other(0x7E)))
    }

    func testDeviceStateRidesTheTouchOpcode() {
        // The arms volunteer wear state on 0xF5 with the same codes 0x2B uses.
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x06])), .glassesState(.wearing))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x07])), .glassesState(.off))
        XCTAssertEqual(G1Inbound.decode(Data([0xF5, 0x0A, 0x5A])), .battery(percent: 90))
    }

    func testMicAudioDropsOpcodeAndSequence() {
        XCTAssertEqual(G1Inbound.decode(Data([0xF1, 0x07, 0xAA, 0xBB])), .micAudio(Data([0xAA, 0xBB])))
    }

    func testFirmwareStringIsTrimmedOfPadding() {
        XCTAssertEqual(G1Inbound.decode(Data([0x6E] + Array("1.6.6".utf8) + [0x00])), .firmware("1.6.6"))
    }

    func testMacAddressFallsBackToHex() {
        XCTAssertEqual(G1Inbound.decode(Data([0x2D, 0xAA, 0xBB, 0xCC])), .macAddress("AA:BB:CC"))
        XCTAssertEqual(G1Inbound.decode(Data([0x2D] + Array("AA:BB".utf8))), .macAddress("AA:BB"))
    }

    func testShortAndUnknownPacketsNeverTrap() {
        XCTAssertEqual(G1Inbound.decode(Data()), .unknown(opcode: 0))
        XCTAssertEqual(G1Inbound.decode(Data([0x2C])), .unknown(opcode: 0x2C))
        XCTAssertEqual(G1Inbound.decode(Data([0xEE, 0x01])), .unknown(opcode: 0xEE))
        XCTAssertEqual(G1Inbound.decode(Data([0x16, 0x01])), .imageVerdict(accepted: false, crc: 0))
    }
}
