import Foundation

/// Packet framing, checksums and command builders for the WHOOP 4.0 BLE protocol.
///
/// Frame layout:
/// ```
/// SOF(0xAA) | length(2, LE) | crc8(1) | payload | crc32(4, LE)
/// payload = type(1) | seq(1) | cmd(1) | data(...)
/// length  = payload.count + 4      // the 4 covers the CRC32 trailer
/// crc8    = CRC-8 over the two length bytes only
/// crc32   = CRC-32 over the payload, stored little-endian
/// ```
public enum WhoopProtocol {

    /// Sequence byte. The strap accepts a fixed value; it is not a rolling counter.
    public static let sequenceByte: UInt8 = 10

    // MARK: - Checksums

    /// CRC-8, polynomial 0x07, init 0x00, no reflection, no final XOR.
    /// Table is generated at load time rather than embedded as a literal.
    static let crc8Table: [UInt8] = {
        (0..<256).map { index -> UInt8 in
            var crc = UInt8(index)
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
            return crc
        }
    }()

    public static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc = crc8Table[Int(crc ^ byte)]
        }
        return crc
    }

    /// CRC-32, polynomial 0xEDB88320 reflected. Identical output to zlib's `crc32`.
    static let crc32Table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1
            }
            return crc
        }
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((result ^ UInt32(byte)) & 0xFF)
            result = crc32Table[index] ^ (result >> 8)
        }
        return result ^ 0xFFFFFFFF
    }

    // MARK: - Framing

    public static func buildPacket(type: PacketType, cmd: WhoopCommand, data: Data = Data()) -> Data {
        buildPacket(type: type, cmdByte: cmd.rawValue, data: data)
    }

    /// Frame a packet for a raw command byte.
    ///
    /// Use this for commands that are not in `WhoopCommand`, such as the
    /// undocumented probes in the 124-139 range.
    public static func buildPacket(type: PacketType, cmdByte: UInt8, data: Data = Data()) -> Data {
        var payload = Data([type.rawValue, sequenceByte, cmdByte])
        payload.append(data)

        let length = UInt16(payload.count + 4)
        let lengthBytes = Data([UInt8(length & 0xFF), UInt8(length >> 8)])

        let crc32Value = crc32(payload)
        let crc32Bytes = Data([
            UInt8(crc32Value & 0xFF),
            UInt8((crc32Value >> 8) & 0xFF),
            UInt8((crc32Value >> 16) & 0xFF),
            UInt8((crc32Value >> 24) & 0xFF)
        ])

        var packet = Data([0xAA])
        packet.append(lengthBytes)
        packet.append(crc8(lengthBytes))
        packet.append(payload)
        packet.append(crc32Bytes)
        return packet
    }

    /// Parse a framed packet. Returns nil when the frame is truncated or the
    /// start-of-frame byte is missing.
    public static func parsePacket(_ raw: Data) -> WhoopPacket? {
        guard raw.count >= 7, raw[raw.startIndex] == 0xAA else { return nil }

        let s = raw.startIndex
        let length = UInt16(raw[s + 1]) | (UInt16(raw[s + 2]) << 8)
        let payloadEnd = s + 4 + Int(length) - 4

        guard Int(length) >= 7, raw.endIndex >= payloadEnd else { return nil }

        let payload = raw[(s + 4)..<payloadEnd]
        guard payload.count >= 3 else { return nil }

        let p = payload.startIndex
        return WhoopPacket(
            type: payload[p],
            seq: payload[p + 1],
            cmd: payload[p + 2],
            data: payload.count > 3 ? Data(payload[(p + 3)...]) : Data()
        )
    }

    /// Verify both checksums on a received frame.
    ///
    /// The strap's own frames are well formed, so this matters most when
    /// re-reading a buffered dump where a resync may have landed mid-packet.
    public static func verifyChecksums(_ raw: Data) -> Bool {
        guard raw.count >= 8, raw[raw.startIndex] == 0xAA else { return false }
        let s = raw.startIndex
        let lengthBytes = raw[(s + 1)..<(s + 3)]
        guard crc8(Data(lengthBytes)) == raw[s + 3] else { return false }

        let length = Int(UInt16(raw[s + 1]) | (UInt16(raw[s + 2]) << 8))
        let payloadEnd = s + 4 + length - 4
        guard raw.endIndex >= payloadEnd + 4 else { return false }

        let payload = Data(raw[(s + 4)..<payloadEnd])
        let expected = crc32(payload)
        let actual = UInt32(raw[payloadEnd])
            | (UInt32(raw[payloadEnd + 1]) << 8)
            | (UInt32(raw[payloadEnd + 2]) << 16)
            | (UInt32(raw[payloadEnd + 3]) << 24)
        return expected == actual
    }
}

// MARK: - Command Builders

public extension WhoopProtocol {

    static func batteryPacket() -> Data {
        buildPacket(type: .command, cmd: .getBatteryLevel, data: Data([0x00]))
    }

    static func clockPacket() -> Data {
        buildPacket(type: .command, cmd: .getClock, data: Data([0x00]))
    }

    static func startHRPacket() -> Data {
        buildPacket(type: .command, cmd: .toggleRealtimeHR, data: Data([0x01]))
    }

    static func stopHRPacket() -> Data {
        buildPacket(type: .command, cmd: .toggleRealtimeHR, data: Data([0x00]))
    }

    static func helloPacket() -> Data {
        buildPacket(type: .command, cmd: .helloApplication, data: Data([0x00]))
    }

    static func setClockPacket(to date: Date) -> Data {
        let now = UInt32(date.timeIntervalSince1970)
        let timeData = Data([
            UInt8(now & 0xFF),
            UInt8((now >> 8) & 0xFF),
            UInt8((now >> 16) & 0xFF),
            UInt8((now >> 24) & 0xFF)
        ])
        return buildPacket(type: .command, cmd: .getClock, data: timeData)
    }

    static func firmwareVersionPacket() -> Data {
        buildPacket(type: .command, cmd: .reportVersionInfo, data: Data([0x00]))
    }

    static func extendedBatteryPacket() -> Data {
        buildPacket(type: .command, cmd: .getExtendedBatteryInfo, data: Data([0x00]))
    }

    static func bodyLocationPacket() -> Data {
        buildPacket(type: .command, cmd: .getBodyLocationAndStatus, data: Data([0x00]))
    }

    static func selectWristPacket(right: Bool) -> Data {
        buildPacket(type: .command, cmd: .selectWrist, data: Data([right ? 0x01 : 0x00]))
    }

    // Haptics

    static func listHapticsPacket() -> Data {
        buildPacket(type: .command, cmd: .getAllHapticsPattern, data: Data([0x00]))
    }

    static func runHapticsPacket(patternId: UInt8) -> Data {
        buildPacket(type: .command, cmd: .runHapticsPattern, data: Data([patternId]))
    }

    static func stopHapticsPacket() -> Data {
        buildPacket(type: .command, cmd: .stopHaptics, data: Data([0x00]))
    }

    // Optical and IMU

    static func startRawOpticalPacket() -> Data {
        buildPacket(type: .command, cmd: .startRawData, data: Data([0x00]))
    }

    static func stopRawOpticalPacket() -> Data {
        buildPacket(type: .command, cmd: .stopRawData, data: Data([0x00]))
    }

    /// Send before `startRawOpticalPacket`. The optical front-end appears to
    /// need this before it will push frames into the BLE pipeline.
    static func enableOpticalDataPacket(_ value: UInt8 = 0x01) -> Data {
        buildPacket(type: .command, cmd: .enableOpticalData, data: Data([value]))
    }

    static func toggleOpticalModePacket(_ value: UInt8 = 0x01) -> Data {
        buildPacket(type: .command, cmd: .toggleOpticalMode, data: Data([value]))
    }

    static func toggleIMUPacket(enable: Bool) -> Data {
        buildPacket(type: .command, cmd: .toggleIMU, data: Data([enable ? 0x01 : 0x00]))
    }

    /// Transimpedance-amplifier gain on the optical front-end. Range depends on
    /// the MAX86171 register configuration, typically 0-7 or 0-15.
    static func setTiaGainPacket(_ value: UInt8) -> Data {
        buildPacket(type: .command, cmd: .setTiaGain, data: Data([value]))
    }

    /// PPG LED drive current, 0-255.
    static func setLedDrivePacket(_ value: UInt8) -> Data {
        buildPacket(type: .command, cmd: .setLedDrive, data: Data([value]))
    }

    // History

    static func requestHistoryPacket() -> Data {
        buildPacket(type: .command, cmd: .sendHistoricalData, data: Data([0x00]))
    }

    /// Acknowledge a history batch and request the next.
    /// - Parameter trim: the trim value from the batch's `HISTORY_END` metadata.
    static func historyAckPacket(trim: UInt32) -> Data {
        var ackData = Data([0x01])
        ackData.append(UInt8(trim & 0xFF))
        ackData.append(UInt8((trim >> 8) & 0xFF))
        ackData.append(UInt8((trim >> 16) & 0xFF))
        ackData.append(UInt8((trim >> 24) & 0xFF))
        ackData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return buildPacket(type: .command, cmd: .historyAck, data: ackData)
    }
}
