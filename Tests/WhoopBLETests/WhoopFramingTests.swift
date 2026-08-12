import XCTest
@testable import WhoopBLE

/// Framing and checksum tests.
///
/// Every fixture here is synthetic. No capture from a real device is used, so
/// the suite runs anywhere without hardware and carries no biometric data.
final class WhoopFramingTests: XCTestCase {

    // MARK: - Checksums

    /// Standard CRC check value: "123456789" over CRC-8 with polynomial 0x07.
    func testCRC8CheckValue() {
        let input = Data("123456789".utf8)
        XCTAssertEqual(WhoopProtocol.crc8(input), 0xF4)
    }

    /// Standard CRC check value: "123456789" over CRC-32, matching zlib.
    func testCRC32CheckValue() {
        let input = Data("123456789".utf8)
        XCTAssertEqual(WhoopProtocol.crc32(input), 0xCBF43926)
    }

    func testCRC8OfEmptyDataIsZero() {
        XCTAssertEqual(WhoopProtocol.crc8(Data()), 0)
    }

    /// The generated table must match the published CRC-8 table at its edges.
    func testCRC8TableSpotValues() {
        XCTAssertEqual(WhoopProtocol.crc8Table.count, 256)
        XCTAssertEqual(WhoopProtocol.crc8Table[0], 0x00)
        XCTAssertEqual(WhoopProtocol.crc8Table[1], 0x07)
        XCTAssertEqual(WhoopProtocol.crc8Table[2], 0x0E)
        XCTAssertEqual(WhoopProtocol.crc8Table[255], 0xF3)
    }

    // MARK: - Frame Structure

    func testBuiltPacketHasExpectedFrameLayout() {
        let packet = WhoopProtocol.buildPacket(
            type: .command,
            cmd: .toggleRealtimeHR,
            data: Data([0x01])
        )

        // SOF + length(2) + crc8 + payload(4) + crc32(4)
        XCTAssertEqual(packet.count, 12)
        XCTAssertEqual(packet[0], 0xAA)

        let length = UInt16(packet[1]) | (UInt16(packet[2]) << 8)
        XCTAssertEqual(length, 8, "payload is 4 bytes plus the 4-byte CRC32 trailer")

        XCTAssertEqual(packet[4], PacketType.command.rawValue)
        XCTAssertEqual(packet[5], WhoopProtocol.sequenceByte)
        XCTAssertEqual(packet[6], WhoopCommand.toggleRealtimeHR.rawValue)
        XCTAssertEqual(packet[7], 0x01)
    }

    func testRoundTripPreservesFields() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packet = WhoopProtocol.buildPacket(type: .command, cmd: .getBatteryLevel, data: payload)

        let parsed = WhoopProtocol.parsePacket(packet)
        XCTAssertEqual(parsed?.type, PacketType.command.rawValue)
        XCTAssertEqual(parsed?.seq, WhoopProtocol.sequenceByte)
        XCTAssertEqual(parsed?.cmd, WhoopCommand.getBatteryLevel.rawValue)
        XCTAssertEqual(parsed?.data, payload)
    }

    func testRoundTripAcrossManyPayloadLengths() {
        for length in 0...64 {
            let payload = Data((0..<length).map { UInt8($0 & 0xFF) })
            let packet = WhoopProtocol.buildPacket(type: .command, cmdByte: 0x2A, data: payload)
            let parsed = WhoopProtocol.parsePacket(packet)
            XCTAssertEqual(parsed?.data, payload, "payload length \(length) did not survive a round trip")
            XCTAssertTrue(WhoopProtocol.verifyChecksums(packet), "checksums failed at payload length \(length)")
        }
    }

    func testEmptyPayloadRoundTrips() {
        let packet = WhoopProtocol.buildPacket(type: .command, cmd: .getClock)
        let parsed = WhoopProtocol.parsePacket(packet)
        XCTAssertEqual(parsed?.cmd, WhoopCommand.getClock.rawValue)
        XCTAssertEqual(parsed?.data.count, 0)
    }

    // MARK: - Rejection

    func testParseRejectsEmptyData() {
        XCTAssertNil(WhoopProtocol.parsePacket(Data()))
    }

    func testParseRejectsMissingStartOfFrame() {
        var packet = WhoopProtocol.buildPacket(type: .command, cmd: .getClock, data: Data([0x00]))
        packet[0] = 0xBB
        XCTAssertNil(WhoopProtocol.parsePacket(packet))
    }

    func testParseRejectsTruncatedFrame() {
        let packet = WhoopProtocol.buildPacket(type: .command, cmd: .getClock, data: Data([0x00]))
        XCTAssertNil(WhoopProtocol.parsePacket(packet.prefix(6)))
    }

    /// A length field larger than the buffer must not read past the end.
    func testParseRejectsOverlongLengthField() {
        var packet = WhoopProtocol.buildPacket(type: .command, cmd: .getClock, data: Data([0x00]))
        packet[1] = 0xFF
        packet[2] = 0xFF
        XCTAssertNil(WhoopProtocol.parsePacket(packet))
    }

    // MARK: - Checksum Verification

    func testVerifyChecksumsAcceptsWellFormedFrame() {
        let packet = WhoopProtocol.buildPacket(type: .command, cmd: .getBatteryLevel, data: Data([0x00]))
        XCTAssertTrue(WhoopProtocol.verifyChecksums(packet))
    }

    func testVerifyChecksumsRejectsCorruptedPayload() {
        var packet = WhoopProtocol.buildPacket(type: .command, cmd: .getBatteryLevel, data: Data([0x00]))
        packet[7] ^= 0xFF
        XCTAssertFalse(WhoopProtocol.verifyChecksums(packet))
    }

    func testVerifyChecksumsRejectsCorruptedLengthHeader() {
        var packet = WhoopProtocol.buildPacket(type: .command, cmd: .getBatteryLevel, data: Data([0x00]))
        packet[3] ^= 0xFF
        XCTAssertFalse(WhoopProtocol.verifyChecksums(packet))
    }

    // MARK: - Command Builders

    func testHRToggleUsesDistinctPayloads() {
        let start = WhoopProtocol.startHRPacket()
        let stop = WhoopProtocol.stopHRPacket()
        XCTAssertEqual(start[7], 0x01)
        XCTAssertEqual(stop[7], 0x00)
        XCTAssertNotEqual(start, stop)
    }

    func testHistoryAckCarriesTrimLittleEndian() {
        let packet = WhoopProtocol.historyAckPacket(trim: 0x11223344)
        let parsed = WhoopProtocol.parsePacket(packet)
        XCTAssertEqual(parsed?.cmd, WhoopCommand.historyAck.rawValue)
        XCTAssertEqual(parsed?.data.prefix(5), Data([0x01, 0x44, 0x33, 0x22, 0x11]))
    }

    func testRawCommandByteBypassesTheEnum() {
        let packet = WhoopProtocol.buildPacket(type: .command, cmdByte: 132)
        XCTAssertEqual(WhoopProtocol.parsePacket(packet)?.cmd, 132)
    }
}
