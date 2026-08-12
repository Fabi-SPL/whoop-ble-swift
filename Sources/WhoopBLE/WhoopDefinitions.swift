import Foundation

// MARK: - BLE UUIDs

public enum WhoopUUID {
    public static let service      = "61080001-8D6D-82B8-614A-1C8CB0F8DCC6"
    public static let cmdToStrap   = "61080002-8D6D-82B8-614A-1C8CB0F8DCC6"
    public static let cmdFromStrap = "61080003-8D6D-82B8-614A-1C8CB0F8DCC6"
    public static let events       = "61080004-8D6D-82B8-614A-1C8CB0F8DCC6"
    public static let data         = "61080005-8D6D-82B8-614A-1C8CB0F8DCC6"
    /// Firmware fault/crash log stream.
    public static let memfault     = "61080007-8D6D-82B8-614A-1C8CB0F8DCC6"
}

// MARK: - Packet Types

public enum PacketType: UInt8 {
    case command         = 35
    case commandResponse = 36
    case realtimeData    = 40
    /// Raw optical (PPG) frames.
    case realtimeRawData = 43
    case historicalData  = 47
    case event           = 48
    case metadata        = 49
    case consoleLogs     = 50
    /// Live IMU (accel + gyro) at 52 Hz.
    case imuRealtime     = 51
    case imuHistorical   = 52
}

// MARK: - Commands

public enum WhoopCommand: UInt8 {
    case toggleRealtimeHR         = 3
    case setLedDrive              = 39
    case setTiaGain               = 41
    case reportVersionInfo        = 7
    case setClock                 = 10
    case getClock                 = 11
    case sendHistoricalData       = 22
    case historyAck               = 23
    case getBatteryLevel          = 26
    /// Handshake with the application MCU.
    case helloApplication         = 35
    case runHapticsPattern        = 79
    case getAllHapticsPattern     = 80
    /// Activate raw optical (PPG) stream, emits type-43.
    case startRawData             = 81
    case stopRawData              = 82
    /// Strap orientation + status.
    case getBodyLocationAndStatus = 84
    /// Voltage, cycles and state of health from the MAX77818 fuel gauge.
    case getExtendedBatteryInfo   = 98
    case toggleIMUHistorical      = 105
    /// Live IMU, emits type-51 at 52 Hz.
    case toggleIMU                = 106
    case enableOpticalData        = 107
    case toggleOpticalMode        = 108
    case stopHaptics              = 122
    /// 0 = left wrist, 1 = right wrist.
    case selectWrist              = 123
    case setResearchPacket        = 131
    case getResearchPacket        = 132
}

// MARK: - Events

public enum WhoopEvent: UInt8 {
    case battery            = 3
    case chargingOn         = 7
    case chargingOff        = 8
    case wristOn            = 9
    case wristOff           = 10
    case doubleTap          = 14
    /// Legacy firmware skin-temperature event.
    case temperatureLevel   = 17
    /// Firmware v68 and later. See `parseEvent32Temperature`.
    case temperatureLevelV2 = 32
    /// Boot-time strap condition report.
    case strapCondition     = 29
    case realtimeHROn       = 33
    case realtimeHROff      = 34
    /// Optical analog front-end reset.
    case afeReset           = 36
    /// LED photodiode channel 1 saturated.
    case ch1Saturation      = 40
    case ch2Saturation      = 41
    /// IMU range exceeded.
    case accelSaturation    = 42
    /// Confirms command 81 was accepted.
    case rawDataOn          = 46
    case rawDataOff         = 47
    case hapticsFired       = 60
    case extendedBattery    = 63
}

// MARK: - Value Types

public struct WhoopPacket: Equatable {
    public let type: UInt8
    public let seq: UInt8
    public let cmd: UInt8
    public let data: Data

    public init(type: UInt8, seq: UInt8, cmd: UInt8, data: Data) {
        self.type = type
        self.seq = seq
        self.cmd = cmd
        self.data = data
    }
}

public struct HRReading: Equatable {
    public let timestamp: UInt32
    public let heartRate: UInt8
    /// Beat-to-beat intervals in milliseconds.
    public let rrIntervals: [UInt16]

    public init(timestamp: UInt32, heartRate: UInt8, rrIntervals: [UInt16]) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.rrIntervals = rrIntervals
    }
}

public struct IMUFrame: Equatable {
    public let timestamp: UInt32
    /// Carried in the packet header, verified against the HR stream.
    public let heartRate: Int32
    public let accelX: Int16
    public let accelY: Int16
    public let accelZ: Int16
    public let gyroX: Int16
    public let gyroY: Int16
    public let gyroZ: Int16

    public init(
        timestamp: UInt32, heartRate: Int32,
        accelX: Int16, accelY: Int16, accelZ: Int16,
        gyroX: Int16, gyroY: Int16, gyroZ: Int16
    ) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
    }

    /// Accelerometer magnitude in milli-g, assuming a range of +/-4g at 8192 LSB/g.
    public var accelMagnitudeMg: Int {
        let ax = Double(accelX) / 8.192
        let ay = Double(accelY) / 8.192
        let az = Double(accelZ) / 8.192
        return Int((ax * ax + ay * ay + az * az).squareRoot())
    }

    /// Normalised movement score from 0 to 1. At rest the magnitude sits near 1g.
    public var movementScore: Double {
        let deviation = abs(Double(accelMagnitudeMg) - 1000.0)
        return min(1.0, deviation / 2000.0)
    }
}

public enum PPGChannel: Int {
    case unknown = 0
    case green1 = 1, green2 = 2, green3 = 3
    case red = 4, infrared = 5
}

public struct PPGSample: Equatable {
    public let timestamp: UInt32
    public let channel: PPGChannel
    /// 19-bit signed ADC value, promoted to Int32.
    public let adc: Int32

    public init(timestamp: UInt32, channel: PPGChannel, adc: Int32) {
        self.timestamp = timestamp
        self.channel = channel
        self.adc = adc
    }
}

public struct ExtendedBattery: Equatable {
    public let voltageMv: Int?
    public let socPct: Double?
    public let stateOfHealthPct: Int?
    public let cycleCount: Int?

    public init(voltageMv: Int?, socPct: Double?, stateOfHealthPct: Int?, cycleCount: Int?) {
        self.voltageMv = voltageMv
        self.socPct = socPct
        self.stateOfHealthPct = stateOfHealthPct
        self.cycleCount = cycleCount
    }
}

/// Decoded 93-byte type-47 sensor packet. See `docs/PROTOCOL.md`.
public struct Type47Decoded: Equatable {
    public let seq: UInt16
    public let timestamp: UInt32
    public let timestampFrac: UInt32
    public let counter: UInt16
    /// 15 IEEE-754 floats from bytes 26 through 85.
    public let floats: [Float]
    public let trailingHex: String

    public init(
        seq: UInt16, timestamp: UInt32, timestampFrac: UInt32,
        counter: UInt16, floats: [Float], trailingHex: String
    ) {
        self.seq = seq
        self.timestamp = timestamp
        self.timestampFrac = timestampFrac
        self.counter = counter
        self.floats = floats
        self.trailingHex = trailingHex
    }
}
