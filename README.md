# WhoopBLE

A Swift package for talking to a WHOOP 4.0 strap over Bluetooth Low Energy.

The strap speaks a private GATT protocol. This package implements the framing, the checksums, the command set and the sensor decoders, so you can read your own heart rate, RR intervals, IMU, skin temperature, battery and raw optical data without the vendor app.

No dependencies. Pure Swift. Runs on iOS 15+ and macOS 12+.

```swift
import WhoopBLE

// Ask the strap for live heart rate
peripheral.writeValue(
    WhoopProtocol.startHRPacket(),
    for: cmdToStrapCharacteristic,
    type: .withoutResponse
)

// Decode what comes back
if let packet = WhoopProtocol.parsePacket(notification),
   packet.type == PacketType.realtimeData.rawValue,
   let reading = WhoopProtocol.parseHRData(cmd: packet.cmd, data: packet.data) {
    print(reading.heartRate, reading.rrIntervals)
}
```

## Install

```swift
.package(url: "https://github.com/Fabi-SPL/whoop-ble-swift.git", from: "1.0.0")
```

Then add `WhoopBLE` to your target's dependencies.

## What it covers

| Area | Status |
|---|---|
| Frame build and parse, CRC-8 and CRC-32 | Complete |
| Live heart rate and RR intervals | Complete |
| Historical data download with acknowledgement loop | Complete |
| IMU at 52 Hz, accelerometer and gyroscope | Complete |
| Skin temperature, three encodings across firmware revisions | Complete |
| Battery, including the fuel gauge registers | Complete |
| Raw optical PPG, MAX86171 FIFO | Partial, see below |
| Haptics, wrist selection, clock | Complete |

The package is transport agnostic. It builds and parses bytes. You bring your own `CoreBluetooth` stack and hand it the five characteristic UUIDs in `WhoopUUID`.

## Protocol notes

`docs/PROTOCOL.md` documents the frame layout, the packet types, the command table, the event table and the byte offsets for every decoder. That file is the useful part if you are implementing this in another language.

## Provenance

The base protocol, meaning the frame layout, the CRC-8 polynomial, the core command identifiers and the IMU packet shape, comes from [jogolden/whoomp](https://github.com/jogolden/whoomp), which reverse engineered the decompiled WHOOP app. This package is an independent Swift implementation of that protocol description rather than a port of its code, and the CRC-8 table is generated from the polynomial rather than copied. The command 107 hypothesis and the realtime temperature encoding come from [bWanShiTong/reverse-engineering-whoop](https://github.com/bWanShiTong/reverse-engineering-whoop).

The following decoders are original work in this repository, derived from byte-offset analysis over captured packets rather than from prior art:

- **Event 32 skin temperature.** Byte-offset scan across 30 captured event-32 packets, 30 of 30 landing inside the plausible skin range at bytes 6 and 7.
- **Extended battery.** MAX77818 ModelGauge m5 register decode, located by scanning candidate base offsets for a plausible cell voltage before trusting any other field.
- **Raw optical PPG.** MAX86171 FIFO decode, 24-bit words split into a 5-bit channel tag and a 19-bit ADC value.
- **Type 47 sensor block.** Byte-variance analysis across 50 samples isolated a 60-byte region of IEEE-754 floats.
- **The extended command and event tables.** Commands 39, 41, 79 to 84, 98, 105 to 108, 122, 123, 131, 132, and events 17, 29, 32, 36, 40 to 42, 46, 47, 60, 63, beyond the set documented in prior work.

## Caveats

Some of this is inference. Where a field is not fully understood the code says so, and the decoders reject implausible values rather than emitting a number that looks real. Temperature outside 25 to 42 degrees is discarded. Timestamps outside a sane epoch window are discarded. This matters because packet types are reused across firmware revisions and a wrong offset produces confident nonsense.

Verified against firmware v1.1.41. Later firmware may move things.

## Tests

```bash
swift test
```

Every fixture in the test suite is synthetic, built byte by byte from the documented layouts. No capture from a real device is committed, so the suite runs anywhere without hardware and the repository carries no biometric data.

## Legal

Not affiliated with or endorsed by WHOOP. This is interoperability work on hardware I own, for reading my own data. MIT licensed.
