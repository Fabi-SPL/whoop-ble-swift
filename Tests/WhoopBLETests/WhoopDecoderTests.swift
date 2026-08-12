import XCTest
@testable import WhoopBLE

/// Decoder tests over hand-built synthetic packets.
///
/// Fixtures are constructed byte by byte from the documented layouts rather than
/// captured from a device, so the expected values are derivable by reading the
/// test and no real biometric data is committed.
final class WhoopDecoderTests: XCTestCase {

    /// 2023-11-14 22:13:20 UTC. Little-endian: 00 F1 53 65.
    private let sampleUnix: UInt32 = 1_700_000_000

    // MARK: - Heart Rate

    func testParseRealtimeHeartRate() {
        // The command byte carries the low byte of the timestamp.
        let cmd: UInt8 = 0x00
        let data = Data([
            0xF1, 0x53, 0x65,   // remaining timestamp bytes
            0x00, 0x00,         // sub-second
            62,                 // heart rate
            2,                  // RR count
            0x84, 0x03,         // 900 ms
            0x8E, 0x03          // 910 ms
        ])

        let reading = WhoopProtocol.parseHRData(cmd: cmd, data: data)
        XCTAssertEqual(reading?.timestamp, sampleUnix)
        XCTAssertEqual(reading?.heartRate, 62)
        XCTAssertEqual(reading?.rrIntervals, [900, 910])
    }

    func testRealtimeHeartRateCapsAtFourIntervals() {
        var data = Data([0xF1, 0x53, 0x65, 0x00, 0x00, 62, 9])
        for _ in 0..<6 { data.append(contentsOf: [0x84, 0x03] as [UInt8]) }
        let reading = WhoopProtocol.parseHRData(cmd: 0x00, data: data)
        XCTAssertEqual(reading?.rrIntervals.count, 4, "the wire format carries at most four intervals")
    }

    func testRealtimeHeartRateRejectsShortPacket() {
        XCTAssertNil(WhoopProtocol.parseHRData(cmd: 0x00, data: Data([0x01, 0x02])))
    }

    func testParseHistoricalRecordUsesItsOwnOffsets() {
        var data = Data(repeating: 0, count: 24)
        data[4] = 0x00; data[5] = 0xF1; data[6] = 0x53; data[7] = 0x65
        data[14] = 71                    // heart rate
        data[15] = 1                     // RR count
        data[16] = 0x52; data[17] = 0x03 // 850 ms

        let reading = WhoopProtocol.parseHistoricalRecord(data: data)
        XCTAssertEqual(reading?.timestamp, sampleUnix)
        XCTAssertEqual(reading?.heartRate, 71)
        XCTAssertEqual(reading?.rrIntervals, [850])
    }

    func testHistoricalRecordRejectsShortPacket() {
        XCTAssertNil(WhoopProtocol.parseHistoricalRecord(data: Data(repeating: 0, count: 23)))
    }

    func testHistoryMetadataTrimIsLittleEndian() {
        var data = Data(repeating: 0, count: 12)
        data[8] = 0x44; data[9] = 0x33; data[10] = 0x22; data[11] = 0x11
        XCTAssertEqual(WhoopProtocol.parseHistoryMetadata(data: data), 0x11223344)
    }

    // MARK: - Battery and Clock

    func testParseBatteryScalesByTen() {
        let data = Data([0x00, 0x00, 0x6A, 0x03])  // 874 -> 87.4 %
        XCTAssertEqual(WhoopProtocol.parseBattery(data) ?? 0, 87.4, accuracy: 0.001)
    }

    func testParseBatteryRejectsShortPacket() {
        XCTAssertNil(WhoopProtocol.parseBattery(Data([0x00, 0x00, 0x6A])))
    }

    func testParseClock() {
        let data = Data([0x00, 0x00, 0x00, 0xF1, 0x53, 0x65])
        XCTAssertEqual(
            WhoopProtocol.parseClock(data)?.timeIntervalSince1970 ?? 0,
            TimeInterval(sampleUnix),
            accuracy: 0.001
        )
    }

    func testParseExtendedBatteryReadsFuelGaugeRegisters() {
        var data = Data(repeating: 0, count: 48)
        data[12] = 0x00; data[13] = 0x55  // RepSOC 0x5500 / 256 = 85 %
        data[14] = 0x00; data[15] = 0x5F  // Age    0x5F00 / 256 = 95 %
        data[18] = 0x00; data[19] = 0xC3  // VCell  49920 * 78.125 uV = 3900 mV
        data[46] = 0x8E; data[47] = 0x00  // Cycles 142

        let battery = WhoopProtocol.parseExtendedBattery(data)
        XCTAssertEqual(battery.voltageMv, 3900)
        XCTAssertEqual(battery.socPct ?? 0, 85.0, accuracy: 0.01)
        XCTAssertEqual(battery.stateOfHealthPct, 95)
        XCTAssertEqual(battery.cycleCount, 142)
    }

    /// Without a plausible cell voltage the whole read is rejected rather than
    /// returning fields decoded from the wrong offset.
    func testExtendedBatteryRejectsImplausibleVoltage() {
        let battery = WhoopProtocol.parseExtendedBattery(Data(repeating: 0, count: 48))
        XCTAssertNil(battery.voltageMv)
        XCTAssertNil(battery.cycleCount)
    }

    func testDecodeFirmwareVersionSplitsBothProcessors() {
        var data = Data(repeating: 0, count: 3 + 16 * 4)
        func writeField(_ index: Int, _ value: UInt8) {
            data[3 + index * 4] = value
        }
        writeField(0, 1); writeField(1, 1); writeField(2, 41); writeField(3, 0)
        writeField(4, 2); writeField(5, 0); writeField(6, 7); writeField(7, 3)

        let version = WhoopProtocol.decodeFirmwareVersion(from: data)
        XCTAssertEqual(version?.application, "1.1.41.0")
        XCTAssertEqual(version?.ble, "2.0.7.3")
        XCTAssertEqual(version?.meta.count, 8)
    }

    // MARK: - Temperature

    func testLegacyTemperatureDecodesMax6631Register() {
        // 33 C arrives as register 0x2100, little-endian on the wire.
        XCTAssertEqual(WhoopProtocol.parseTemperature(Data([0x00, 0x21])) ?? 0, 33.0, accuracy: 0.001)
    }

    func testEvent32TemperatureReadsBytesSixAndSeven() {
        var data = Data(repeating: 0, count: 8)
        data[6] = 0x80; data[7] = 0x21  // 8576 / 256 = 33.5 C
        XCTAssertEqual(WhoopProtocol.parseEvent32Temperature(data) ?? 0, 33.5, accuracy: 0.001)
    }

    /// A value outside the skin range means the packet was not a temperature
    /// reading. Returning nil is what keeps foreign packets out of the data set.
    func testTemperatureOutsideSkinRangeIsRejected() {
        var data = Data(repeating: 0, count: 8)
        data[6] = 0x00; data[7] = 0x64  // 25600 / 256 = 100 C
        XCTAssertNil(WhoopProtocol.parseEvent32Temperature(data))
    }

    func testRealtimeTemperatureDecodes48BitField() {
        var data = Data(repeating: 0, count: 10)
        // 3_312_000 / 100_000 = 33.12 C
        let raw: UInt64 = 3_312_000
        for i in 0..<6 { data[4 + i] = UInt8((raw >> (8 * i)) & 0xFF) }
        XCTAssertEqual(WhoopProtocol.parseRealtimeTemperature(data: data) ?? 0, 33.12, accuracy: 0.001)
    }

    // MARK: - IMU

    func testParseIMUFrame() {
        let data = Data([
            0xF1, 0x53, 0x65,       // timestamp continued
            0x00, 0x00,             // sub-second
            65, 0x00, 0x00, 0x00,   // heart rate, int32 LE
            0x64, 0x00,             // accel x   100
            0xC8, 0x00,             // accel y   200
            0x00, 0x20,             // accel z   8192, one g
            0xCE, 0xFF,             // gyro x    -50
            0x00, 0x00,             // gyro y    0
            0x19, 0x00              // gyro z    25
        ])

        let frames = WhoopProtocol.parseIMUPacket(cmd: 0x00, data: data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.timestamp, sampleUnix)
        XCTAssertEqual(frames.first?.heartRate, 65)
        XCTAssertEqual(frames.first?.accelX, 100)
        XCTAssertEqual(frames.first?.accelZ, 8192)
        XCTAssertEqual(frames.first?.gyroX, -50)
    }

    func testIMUFramesAreBatchedTwelveBytesApart() {
        var data = Data([0xF1, 0x53, 0x65, 0x00, 0x00, 65, 0x00, 0x00, 0x00])
        data.append(Data(repeating: 0, count: 12 * 3))
        XCTAssertEqual(WhoopProtocol.parseIMUPacket(cmd: 0x00, data: data).count, 3)
    }

    /// Packet types are reused across firmware revisions. An implausible
    /// timestamp is the cheapest signal that this is not really an IMU packet.
    func testIMURejectsImplausibleTimestamp() {
        var data = Data(repeating: 0, count: 21)
        data[0] = 0xFF; data[1] = 0xFF; data[2] = 0xFF
        XCTAssertTrue(WhoopProtocol.parseIMUPacket(cmd: 0xFF, data: data).isEmpty)
    }

    func testAccelMagnitudeAtRestIsAboutOneG() {
        let frame = IMUFrame(
            timestamp: sampleUnix, heartRate: 60,
            accelX: 0, accelY: 0, accelZ: 8192,
            gyroX: 0, gyroY: 0, gyroZ: 0
        )
        XCTAssertEqual(frame.accelMagnitudeMg, 1000)
        XCTAssertEqual(frame.movementScore, 0.0, accuracy: 0.001)
    }

    // MARK: - Raw Optical

    func testParsePPGSamplesAndChannelTags() {
        var data = Data([0xF1, 0x53, 0x65, 0x00, 0x00])  // header continued
        // Tag 4 (red), ADC 0x00001. Word = (4 << 19) | 1 = 0x200001.
        data.append(contentsOf: [0x20, 0x00, 0x01])
        // Tag 5 (infrared), ADC 0x00002. Word = (5 << 19) | 2 = 0x280002.
        data.append(contentsOf: [0x28, 0x00, 0x02])

        let samples = WhoopProtocol.parsePPGPacket(cmd: 0x00, data: data)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.first?.channel, PPGChannel.red)
        XCTAssertEqual(samples.first?.adc, 1)
        XCTAssertEqual(samples.last?.channel, PPGChannel.infrared)
        XCTAssertEqual(samples.last?.adc, 2)
    }

    func testPPGRejectsImplausibleTimestamp() {
        let data = Data(repeating: 0xFF, count: 16)
        XCTAssertTrue(WhoopProtocol.parsePPGPacket(cmd: 0xFF, data: data).isEmpty)
    }

    // MARK: - Type 47

    func testParseType47Packet() {
        var data = Data(repeating: 0, count: 93)
        data[0] = 0x01                                       // sequence
        data[4] = 0x00; data[5] = 0xF1; data[6] = 0x53; data[7] = 0x65
        data[14] = 0x05                                      // counter
        data[26] = 0x00; data[27] = 0x00; data[28] = 0x80; data[29] = 0x3F  // 1.0f
        for i in 0..<7 { data[86 + i] = UInt8(i + 1) }

        let decoded = WhoopProtocol.parseType47Packet(data)
        XCTAssertEqual(decoded?.seq, 1)
        XCTAssertEqual(decoded?.timestamp, sampleUnix)
        XCTAssertEqual(decoded?.counter, 5)
        XCTAssertEqual(decoded?.floats.count, 15)
        XCTAssertEqual(decoded?.floats.first ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(decoded?.trailingHex, "01020304050607")
    }

    func testType47RejectsShortPacket() {
        XCTAssertNil(WhoopProtocol.parseType47Packet(Data(repeating: 0, count: 92)))
    }
}
