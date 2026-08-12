import Foundation

// MARK: - Heart Rate

public extension WhoopProtocol {

    /// Realtime heart rate, packet type 40 on the DATA characteristic.
    ///
    /// The command byte is part of the value, not a separate header field, so it
    /// is prepended before unpacking:
    /// `[unix uint32 LE][subsec uint16 LE][hr uint8][rrCount uint8]` then
    /// `rrCount` intervals as uint16 LE, capped at 4.
    static func parseHRData(cmd: UInt8, data: Data) -> HRReading? {
        guard data.count >= 7 else { return nil }

        var recon = Data([cmd])
        recon.append(data[data.startIndex..<(data.startIndex + 7)])

        let unix = UInt32(recon[0])
            | (UInt32(recon[1]) << 8)
            | (UInt32(recon[2]) << 16)
            | (UInt32(recon[3]) << 24)
        let heart = recon[6]
        let rrCount = recon[7]

        var rrIntervals: [UInt16] = []
        if rrCount > 0 {
            for i in 0..<min(Int(rrCount), 4) {
                let offset = data.startIndex + 7 + i * 2
                guard offset + 1 < data.endIndex else { break }
                let rr = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                if rr > 0 { rrIntervals.append(rr) }
            }
        }

        return HRReading(timestamp: unix, heartRate: heart, rrIntervals: rrIntervals)
    }

    /// Historical heart rate record, packet type 47.
    ///
    /// Layout differs from the realtime record: there are four leading bytes to
    /// skip and the unknown field is uint32, not uint16.
    /// `[4 skip][unix uint32][subsec uint16][unknown uint32][hr uint8][rrCount uint8][rr1-4 uint16]`
    static func parseHistoricalRecord(data: Data) -> HRReading? {
        guard data.count >= 24 else { return nil }

        let s = data.startIndex
        let unix = UInt32(data[s + 4])
            | (UInt32(data[s + 5]) << 8)
            | (UInt32(data[s + 6]) << 16)
            | (UInt32(data[s + 7]) << 24)
        let heart = data[s + 14]
        let rrCount = data[s + 15]

        var rrIntervals: [UInt16] = []
        if rrCount > 0 {
            for i in 0..<min(Int(rrCount), 4) {
                let offset = s + 16 + i * 2
                guard offset + 1 < data.endIndex else { break }
                let rr = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                if rr > 0 { rrIntervals.append(rr) }
            }
        }

        return HRReading(timestamp: unix, heartRate: heart, rrIntervals: rrIntervals)
    }

    /// Trim value from `HISTORY_END` metadata, packet type 49 command 2.
    /// Feed the result to `historyAckPacket(trim:)` to request the next batch.
    ///
    /// The offset is empirical. Some captures place the field two bytes later,
    /// so treat an implausible trim as a signal to resync rather than to trust.
    static func parseHistoryMetadata(data: Data) -> UInt32? {
        guard data.count >= 12 else { return nil }
        let offset = data.startIndex + 8
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

// MARK: - Battery and Clock

public extension WhoopProtocol {

    /// Battery percentage from a command-26 response: uint16 LE at offset 2, scaled by 1/10.
    static func parseBattery(_ data: Data) -> Double? {
        guard data.count >= 4 else { return nil }
        let raw = UInt16(data[data.startIndex + 2]) | (UInt16(data[data.startIndex + 3]) << 8)
        return Double(raw) / 10.0
    }

    /// Device clock from a command-11 response: uint32 LE unix seconds at offset 2.
    static func parseClock(_ data: Data) -> Date? {
        guard data.count >= 6 else { return nil }
        let o = data.startIndex + 2
        let unix = UInt32(data[o])
            | (UInt32(data[o + 1]) << 8)
            | (UInt32(data[o + 2]) << 16)
            | (UInt32(data[o + 3]) << 24)
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    /// Fuel-gauge registers from a command-98 response.
    ///
    /// The strap returns a MAX77818 ModelGauge m5 register dump. Offsets and
    /// scales come from the Maxim datasheet:
    ///
    /// | Register | Offset | Scale |
    /// |---|---|---|
    /// | RepSOC | 0x06 | 1/256 % per LSB |
    /// | Age (state of health) | 0x07 | 1/256 % per LSB |
    /// | VCell | 0x09 | 78.125 uV per LSB |
    /// | Cycles | 0x17 | 1 % per LSB |
    ///
    /// The response prefixes the block with a small, variable number of metadata
    /// bytes, so candidate base offsets are tried and gated on a plausible cell
    /// voltage before the remaining fields are trusted.
    static func parseExtendedBattery(_ data: Data) -> ExtendedBattery {
        func u16(_ offset: Int) -> Int? {
            let start = data.startIndex + offset
            guard start + 1 < data.endIndex else { return nil }
            return Int(data[start]) | (Int(data[start + 1]) << 8)
        }

        for base in [0, 2, 4] {
            guard let vRaw = u16(base + 0x09 * 2) else { continue }
            let mv = Int(Double(vRaw) * 78.125 / 1000.0)
            guard mv > 2500 && mv < 5000 else { continue }

            let socPct = Double(u16(base + 0x06 * 2) ?? 0) / 256.0
            let soh = Int(Double(u16(base + 0x07 * 2) ?? 0) / 256.0)
            let cycles = u16(base + 0x17 * 2) ?? 0

            return ExtendedBattery(
                voltageMv: mv,
                socPct: socPct > 0 && socPct <= 100 ? socPct : nil,
                stateOfHealthPct: soh > 0 && soh <= 100 ? soh : nil,
                cycleCount: cycles >= 0 && cycles < 10000 ? cycles : nil
            )
        }
        return ExtendedBattery(voltageMv: nil, socPct: nil, stateOfHealthPct: nil, cycleCount: nil)
    }

    /// Firmware versions from a command-7 response.
    ///
    /// Three status bytes followed by 16 uint32 LE fields. The first four are the
    /// application MCU version, the next four the BLE chip version, the rest are
    /// build metadata.
    static func decodeFirmwareVersion(from data: Data) -> (application: String, ble: String, meta: [UInt32])? {
        guard data.count >= 3 + 16 * 4 else { return nil }

        var fields: [UInt32] = []
        var i = data.startIndex + 3
        while i + 4 <= data.endIndex && fields.count < 16 {
            fields.append(
                UInt32(data[i])
                    | (UInt32(data[i + 1]) << 8)
                    | (UInt32(data[i + 2]) << 16)
                    | (UInt32(data[i + 3]) << 24)
            )
            i += 4
        }
        guard fields.count >= 8 else { return nil }

        let application = "\(fields[0]).\(fields[1]).\(fields[2]).\(fields[3])"
        let ble = "\(fields[4]).\(fields[5]).\(fields[6]).\(fields[7])"
        return (application, ble, Array(fields.dropFirst(8)))
    }
}

// MARK: - Temperature

public extension WhoopProtocol {

    /// Plausible skin-temperature window in Celsius. Anything outside it means
    /// the packet was not a temperature reading.
    static let skinTemperatureRange: ClosedRange<Double> = 25.0...42.0

    /// Skin temperature from event 17, older firmware.
    ///
    /// The sensor is a MAX6631MTT: a 12-bit signed register where the high byte
    /// is whole degrees Celsius and the low byte is the fraction, transmitted
    /// little-endian. So 33 C arrives as 0x2100, read as 8448, divided by 256.
    ///
    /// Some firmware variants prepend a one-byte status field, so both offsets
    /// are tried, and two legacy fixed-point scales are kept as fallbacks.
    static func parseTemperature(_ data: Data) -> Double? {
        guard data.count >= 2 else { return nil }

        for offset in [0, 1] {
            guard data.count >= offset + 2 else { continue }
            let raw = UInt16(data[data.startIndex + offset])
                | (UInt16(data[data.startIndex + offset + 1]) << 8)
            let signed = Int16(bitPattern: raw)

            for divisor in [256.0, 100.0, 10.0] {
                let tempC = Double(signed) / divisor
                if skinTemperatureRange.contains(tempC) { return tempC }
            }
        }
        return nil
    }

    /// Skin temperature from event 32, firmware v68 and later.
    ///
    /// Found by scanning every byte offset across 30 captured event-32 packets
    /// and keeping the offset whose decoded value landed in the plausible skin
    /// range every time. Bytes 6 and 7 as int16 LE over 256 hit 30 of 30.
    ///
    /// Layout of a typical 13 to 41 byte packet:
    /// ```
    /// [0]     status flag, 0x00 when ok
    /// [1..4]  unix timestamp seconds LE
    /// [5]     subtype
    /// [6..7]  temperature, int16 LE, divide by 256
    /// [8..]   further sensor metadata, length varies
    /// ```
    static func parseEvent32Temperature(_ data: Data) -> Double? {
        guard data.count >= 8 else { return nil }
        let raw = UInt16(data[data.startIndex + 6]) | (UInt16(data[data.startIndex + 7]) << 8)
        let tempC = Double(Int16(bitPattern: raw)) / 256.0
        return skinTemperatureRange.contains(tempC) ? tempC : nil
    }

    /// Skin temperature streamed continuously on packet type 49.
    ///
    /// `[0..3]` unix timestamp LE, `[4..9]` a 48-bit little-endian integer that
    /// divides by 100,000 to give Celsius. The accepted range is widened here
    /// because type 49 also carries genuine metadata during a history sync, and
    /// an out-of-range result is the signal that this packet is not temperature.
    static func parseRealtimeTemperature(data: Data) -> Double? {
        guard data.count >= 10 else { return nil }
        var raw: UInt64 = 0
        for i in 0..<6 {
            raw |= UInt64(data[data.startIndex + 4 + i]) << (8 * i)
        }
        let tempC = Double(raw) / 100_000.0
        return (tempC >= 20.0 && tempC <= 45.0) ? tempC : nil
    }
}

// MARK: - IMU

public extension WhoopProtocol {

    /// Plausible unix-timestamp window used to reject misclassified packets.
    static let plausibleTimestamps: ClosedRange<UInt32> = 1_600_000_000...2_500_000_000

    /// IMU frames from a type-51 realtime packet.
    ///
    /// A 10-byte header followed by one or more 12-byte frames:
    /// ```
    /// header: [unix uint32 LE][subsec uint16 LE][hr int32 LE]
    /// frame:  [ax][ay][az][gx][gy][gz]   // six int16 LE, 12 bytes
    /// ```
    /// Scales: +/-4g at 8192 LSB/g for the accelerometer, +/-250 dps at
    /// 131 LSB/dps for the gyroscope.
    ///
    /// The timestamp gate matters. Packet types are reused across firmware
    /// revisions, and an implausible timestamp is the cheapest reliable signal
    /// that this packet is not what the type byte claims.
    static func parseIMUPacket(cmd: UInt8, data: Data) -> [IMUFrame] {
        var recon = Data([cmd])
        recon.append(data)
        guard recon.count >= 22 else { return [] }

        let unix = UInt32(recon[0])
            | (UInt32(recon[1]) << 8)
            | (UInt32(recon[2]) << 16)
            | (UInt32(recon[3]) << 24)
        guard plausibleTimestamps.contains(unix) else { return [] }

        let hr = Int32(bitPattern:
            UInt32(recon[6])
                | (UInt32(recon[7]) << 8)
                | (UInt32(recon[8]) << 16)
                | (UInt32(recon[9]) << 24)
        )

        func int16(_ i: Int) -> Int16 {
            Int16(bitPattern: UInt16(recon[i]) | (UInt16(recon[i + 1]) << 8))
        }

        var frames: [IMUFrame] = []
        var i = recon.startIndex + 10
        while i + 12 <= recon.endIndex {
            frames.append(IMUFrame(
                timestamp: unix,
                heartRate: hr,
                accelX: int16(i), accelY: int16(i + 2), accelZ: int16(i + 4),
                gyroX: int16(i + 6), gyroY: int16(i + 8), gyroZ: int16(i + 10)
            ))
            i += 12
        }
        return frames
    }
}

// MARK: - Raw Optical (PPG)

public extension WhoopProtocol {

    /// PPG samples from a type-43 raw optical packet.
    ///
    /// The body is a MAX86171 FIFO: three bytes per sample, big-endian, packing
    /// a 5-bit channel tag above a 19-bit signed ADC value. Whoop wraps the FIFO
    /// with a timestamp header whose length varies, so both observed header
    /// lengths are tried and the first that yields samples wins.
    static func parsePPGPacket(cmd: UInt8, data: Data) -> [PPGSample] {
        var recon = Data([cmd])
        recon.append(data)
        guard recon.count >= 9 else { return [] }

        let unix = UInt32(recon[0])
            | (UInt32(recon[1]) << 8)
            | (UInt32(recon[2]) << 16)
            | (UInt32(recon[3]) << 24)
        guard plausibleTimestamps.contains(unix) else { return [] }

        for headerLength in [6, 10] {
            var out: [PPGSample] = []
            var i = recon.startIndex + headerLength
            while i + 3 <= recon.endIndex {
                let word = (UInt32(recon[i]) << 16) | (UInt32(recon[i + 1]) << 8) | UInt32(recon[i + 2])
                let tag = Int((word >> 19) & 0x1F)

                var adc = Int32(word & 0x7FFFF)
                if adc & 0x40000 != 0 { adc -= 0x80000 }

                let channel: PPGChannel
                switch tag {
                case 1, 2, 3: channel = .green1
                case 4:       channel = .red
                case 5:       channel = .infrared
                default:      channel = .unknown
                }

                out.append(PPGSample(timestamp: unix, channel: channel, adc: adc))
                i += 3
            }
            if !out.isEmpty { return out }
        }
        return []
    }
}

// MARK: - Type-47 Sensor Packet

public extension WhoopProtocol {

    /// Decode the 93-byte type-47 packet seen on firmware v1.1.41.
    ///
    /// These arrive in bursts after a BLE reconnect. Byte-variance analysis over
    /// 50 samples showed 25 or more bytes in the 26 to 85 region with a range of
    /// 195 to 255, which is signal, not padding. Reading that region as 15
    /// IEEE-754 floats produces stable values.
    ///
    /// ```
    /// [0..1]   sequence or type indicator
    /// [2..3]   0x0003 constant subtype marker
    /// [4..7]   unix timestamp seconds LE
    /// [8..11]  sub-second LE
    /// [12]     0x4A constant
    /// [13]     0x01 constant
    /// [14..15] incrementing counter, uint16 LE
    /// [16..25] zero padding
    /// [26..85] 15 floats, 4 bytes each LE
    /// [86..92] trailing bytes, alignment or next-chunk marker
    /// ```
    ///
    /// The float ordering is not yet identified. The likely contents are
    /// accelerometer XYZ, gyroscope XYZ and normalised PPG channels; confirming
    /// it needs a capture correlating motion against stillness.
    static func parseType47Packet(_ data: Data) -> Type47Decoded? {
        guard data.count >= 93 else { return nil }
        let s = data.startIndex

        let seq = UInt16(data[s]) | (UInt16(data[s + 1]) << 8)
        let ts = UInt32(data[s + 4])
            | (UInt32(data[s + 5]) << 8)
            | (UInt32(data[s + 6]) << 16)
            | (UInt32(data[s + 7]) << 24)
        let tsFrac = UInt32(data[s + 8])
            | (UInt32(data[s + 9]) << 8)
            | (UInt32(data[s + 10]) << 16)
            | (UInt32(data[s + 11]) << 24)
        let counter = UInt16(data[s + 14]) | (UInt16(data[s + 15]) << 8)

        var floats: [Float] = []
        floats.reserveCapacity(15)
        for i in 0..<15 {
            let o = s + 26 + i * 4
            let raw = UInt32(data[o])
                | (UInt32(data[o + 1]) << 8)
                | (UInt32(data[o + 2]) << 16)
                | (UInt32(data[o + 3]) << 24)
            floats.append(Float(bitPattern: raw))
        }

        let trailing = data[(s + 86)..<(s + 93)].map { String(format: "%02x", $0) }.joined()
        return Type47Decoded(
            seq: seq,
            timestamp: ts,
            timestampFrac: tsFrac,
            counter: counter,
            floats: floats,
            trailingHex: trailing
        )
    }
}
