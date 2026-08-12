# WHOOP 4.0 BLE protocol

Everything below is observed behaviour on firmware v1.1.41. It is not official documentation and WHOOP has never published a spec. Where a field is inferred rather than confirmed, it says so.

Base protocol credit: [jogolden/whoomp](https://github.com/jogolden/whoomp) for the frame layout, CRC-8 polynomial, core command set and IMU packet shape. [bWanShiTong/reverse-engineering-whoop](https://github.com/bWanShiTong/reverse-engineering-whoop) for command 107 and the realtime temperature encoding. The remainder is documented here for the first time.

## GATT

One custom service, five characteristics.

| Role | UUID | Properties |
|---|---|---|
| Service | `61080001-8D6D-82B8-614A-1C8CB0F8DCC6` | |
| Command to strap | `61080002-8D6D-82B8-614A-1C8CB0F8DCC6` | write without response |
| Command from strap | `61080003-8D6D-82B8-614A-1C8CB0F8DCC6` | notify |
| Events | `61080004-8D6D-82B8-614A-1C8CB0F8DCC6` | notify |
| Data | `61080005-8D6D-82B8-614A-1C8CB0F8DCC6` | notify |
| Memfault | `61080007-8D6D-82B8-614A-1C8CB0F8DCC6` | notify |

Memfault carries firmware fault and crash logs. It is safe to ignore.

Write commands with `.withoutResponse`. The strap does not ack at the ATT layer; it answers on the notify characteristics.

## Frame

```
+------+-------------+-------+-----------------+-----------+
| 0xAA | length (2)  | crc8  | payload         | crc32 (4) |
+------+-------------+-------+-----------------+-----------+
```

- `length` is uint16 little-endian and equals `payload.count + 4`. The 4 covers the CRC-32 trailer, not the header.
- `crc8` is CRC-8 over the two length bytes only, not over the payload. Polynomial 0x07, init 0x00, no reflection, no final XOR. Check value for `"123456789"` is `0xF4`.
- `crc32` is standard CRC-32 over the payload, stored little-endian. Identical output to zlib.

Payload:

```
+--------+--------+--------+------------+
| type   | seq    | cmd    | data ...   |
+--------+--------+--------+------------+
```

`seq` is a fixed value in practice. The strap accepts a constant and does not appear to validate it as a rolling counter.

**Practical warning.** The command byte is part of the payload, so on notify characteristics that split a record across the header boundary you must prepend `cmd` back onto `data` before unpacking. The heart rate, IMU and PPG decoders all do this. Forgetting it shifts every field by one byte and produces plausible looking garbage.

## Packet types

| Value | Meaning |
|---|---|
| 35 | Command to strap |
| 36 | Command response |
| 40 | Realtime data, heart rate |
| 43 | Realtime raw data, PPG |
| 47 | Historical data, also a 93-byte sensor block, see below |
| 48 | Event |
| 49 | Metadata, also realtime temperature |
| 50 | Console logs |
| 51 | IMU realtime, 52 Hz |
| 52 | IMU historical |

Types are reused across firmware revisions and across purposes. Type 47 carries both historical heart rate records and an unrelated 93-byte sensor block. Type 49 carries both history metadata and streamed temperature. This is why every decoder here gates on a plausible value range and returns nothing rather than guessing.

## Commands

| ID | Name | Notes |
|---|---|---|
| 3 | Toggle realtime HR | data `01` on, `00` off |
| 7 | Report version info | |
| 10 | Set clock | uint32 LE unix seconds |
| 11 | Get clock | |
| 22 | Send historical data | starts the download |
| 23 | History ack | `01` + trim uint32 LE + four zero bytes |
| 26 | Get battery level | |
| 35 | Hello, application MCU | |
| 39 | Set LED drive | 0 to 255 |
| 41 | Set TIA gain | typically 0 to 7 or 0 to 15 |
| 79 | Run haptics pattern | pattern id |
| 80 | Get all haptics patterns | |
| 81 | Start raw data | emits type 43 |
| 82 | Stop raw data | |
| 84 | Get body location and status | |
| 98 | Get extended battery info | fuel gauge dump |
| 105 | Toggle IMU historical | |
| 106 | Toggle IMU | emits type 51 at 52 Hz |
| 107 | Enable optical data | send before 81 |
| 108 | Toggle optical mode | |
| 122 | Stop haptics | |
| 123 | Select wrist | `00` left, `01` right |
| 131 | Set research packet | |
| 132 | Get research packet | |

Commands 124, 125 and 139 respond but their semantics are unidentified. Build packets for them with the raw-byte overload:

```swift
WhoopProtocol.buildPacket(type: .command, cmdByte: 139)
```

## Events

Delivered on the events characteristic as packet type 48.

| ID | Meaning |
|---|---|
| 3 | Battery |
| 7 | Charging on |
| 8 | Charging off |
| 9 | Wrist on |
| 10 | Wrist off |
| 14 | Double tap |
| 17 | Temperature, legacy encoding |
| 29 | Strap condition, emitted at boot |
| 32 | Temperature, firmware v68 and later |
| 33 | Realtime HR on |
| 34 | Realtime HR off |
| 36 | Optical analog front end reset |
| 40 | Photodiode channel 1 saturated |
| 41 | Photodiode channel 2 saturated |
| 42 | Accelerometer range exceeded |
| 46 | Raw data on, confirms command 81 |
| 47 | Raw data off |
| 60 | Haptics fired |
| 63 | Extended battery |

## Realtime heart rate

Packet type 40 on the data characteristic. Reconstruct as `[cmd] + data`, then:

```
[0..3]  unix seconds, uint32 LE
[4..5]  sub-second, uint16 LE
[6]     heart rate, uint8 bpm
[7]     RR interval count
[8..]   RR intervals, uint16 LE milliseconds, at most 4
```

Zero-valued RR intervals are padding and should be dropped.

## Historical heart rate

Packet type 47, requested with command 22. Different layout from the realtime record. There are four leading bytes to skip and the unknown field is uint32 rather than uint16:

```
[0..3]   skip
[4..7]   unix seconds, uint32 LE
[8..9]   sub-second, uint16 LE
[10..13] unknown, uint32
[14]     heart rate
[15]     RR interval count
[16..]   RR intervals, uint16 LE
```

The download is a request and acknowledge loop. After each batch the strap sends `HISTORY_END` as packet type 49 command 2, carrying a trim value at offset 8 as uint32 LE. Echo that trim back with command 23 to receive the next batch. The offset is empirical and some captures place it two bytes later, so treat an implausible trim as a signal to resync rather than as a value to trust.

## IMU

Command 106 enables it. Frames arrive as packet type 51 at 52 Hz. Reconstruct as `[cmd] + data`:

```
header: [0..3]  unix seconds, uint32 LE
        [4..5]  sub-second, uint16 LE
        [6..9]  heart rate, int32 LE
frame:  [ax][ay][az][gx][gy][gz]    six int16 LE, 12 bytes
```

One packet carries one or more frames. Scales are 8192 LSB per g on the accelerometer at plus or minus 4g, and 131 LSB per degree per second on the gyroscope at plus or minus 250 dps. At rest the accelerometer magnitude sits near 1000 mg, which is a useful sanity check on the offsets.

## Temperature

Three encodings, depending on firmware and transport.

**Event 17, legacy.** The sensor is a MAX6631MTT. A 12-bit signed register where the high byte is whole degrees Celsius and the low byte is the fraction, transmitted little-endian. So 33 C arrives as `00 21`, read as 8448, divided by 256. Some firmware variants prepend a one-byte status field, so try offsets 0 and 1.

**Event 32, firmware v68 and later.** Bytes 6 and 7 as int16 LE, divided by 256.

```
[0]     status flag, 0x00 when ok
[1..4]  unix seconds LE
[5]     subtype
[6..7]  temperature, int16 LE, divide by 256
[8..]   further metadata, length varies between 13 and 41 bytes total
```

This offset was found by scanning every byte position across 30 captured event-32 packets and keeping the one whose decoded value landed inside a plausible skin range every time. Bytes 6 and 7 hit 30 of 30.

**Packet type 49, streamed.** `[0..3]` unix seconds LE, `[4..9]` a 48-bit little-endian integer that divides by 100,000 to give Celsius.

In all three cases, reject anything outside roughly 25 to 42 C. Type 49 in particular also carries genuine history metadata, and an out-of-range result is the signal that the packet is not a temperature reading at all.

## Battery

**Command 26.** uint16 LE at offset 2, divided by 10, giving a percentage to one decimal place.

**Command 98, extended.** The strap returns a MAX77818 ModelGauge m5 register dump. Register addresses are 16-bit words, so a register index maps to a byte offset of `index * 2`.

| Register | Index | Scale |
|---|---|---|
| RepSOC | 0x06 | 1/256 percent per LSB |
| Age, state of health | 0x07 | 1/256 percent per LSB |
| VCell | 0x09 | 78.125 microvolts per LSB |
| Cycles | 0x17 | 1 percent per LSB |

The response prefixes the register block with a small and variable number of metadata bytes. Rather than hardcode a base offset, try 0, 2 and 4, and accept a base only if VCell decodes to a plausible cell voltage between 2500 and 5000 mV. Then read the remaining fields from the same base. Gating on one well-constrained field before trusting the rest is what stops a wrong base offset from producing a confident wrong answer.

## Raw optical, PPG

Send command 107 first, then command 81. Event 46 confirms the stream is on. Without command 107 the optical front end does not push frames into the BLE pipeline.

Frames arrive as packet type 43. The body is a MAX86171 FIFO: three bytes per sample, big-endian, packing a 5-bit channel tag above a 19-bit signed ADC value.

```
word = (b0 << 16) | (b1 << 8) | b2
tag  = (word >> 19) & 0x1F
adc  = word & 0x7FFFF          // sign-extend from bit 18
```

| Tag | Channel |
|---|---|
| 1, 2, 3 | Green |
| 4 | Red |
| 5 | Infrared |

The header length before the FIFO varies. Both 6 and 10 have been observed, so try both and take the first that yields samples.

LED drive current is set with command 39 and transimpedance amplifier gain with command 41. Saturation shows up as events 40 and 41.

## Type 47, 93-byte sensor block

Distinct from the historical heart rate records that share the type byte. These arrive in bursts after a BLE reconnect.

```
[0..1]   sequence or type indicator
[2..3]   0x0003, constant subtype marker
[4..7]   unix seconds LE
[8..11]  sub-second LE
[12]     0x4A, constant
[13]     0x01, constant
[14..15] incrementing counter, uint16 LE
[16..25] zero padding
[26..85] 15 IEEE-754 floats, 4 bytes each, LE
[86..92] trailing bytes, alignment or next-chunk marker
```

Byte-variance analysis across 50 samples showed 25 or more bytes in the 26 to 85 region with a value range of 195 to 255, which is signal rather than padding. Reading that region as floats produces stable values.

**Unresolved.** The float ordering is not identified. The likely contents are accelerometer XYZ, gyroscope XYZ and normalised PPG channels. Confirming it needs a capture that correlates deliberate motion against stillness. If you take that capture, a pull request is welcome.

## Things that will bite you

- The command byte belongs to the payload. Prepend it before unpacking or every field shifts by one.
- CRC-8 covers the length bytes only. CRC-32 covers the payload. They are not interchangeable and neither covers the whole frame.
- `length` counts the CRC-32 trailer. It is not the payload length.
- Packet types are overloaded. Always range-check the decoded value and discard rather than guess.
- Command 107 before command 81, or the optical stream stays silent while appearing to have been enabled.
