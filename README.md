# EvenG1Kit

A Swift package that talks to [Even Realities G1](https://www.evenrealities.com) smart
glasses over Bluetooth LE. No UI, no dependencies — just the transport, the binary
protocol, and the state that comes back from the hardware.

The G1 exposes each temple as a **separate BLE peripheral**. EvenG1Kit pairs them,
keeps both alive, and gives you one object to talk to.

```swift
import EvenG1Kit

EvenG1SDK.shared.delegate = self
EvenG1SDK.shared.startScan(timeout: 8)
// once connected
EvenG1SDK.shared.sendText("Good morning")
```

## Requirements

- iOS 15+ / macOS 12+
- A **physical device** — CoreBluetooth does not work in the Simulator
- `NSBluetoothAlwaysUsageDescription` in your Info.plist

## Installation

```swift
.package(url: "https://github.com/knd8128/EvenG1Kit.git", from: "1.0.0")
```

## What it covers

| Area | API |
|------|-----|
| Discovery and pairing | `startScan(timeout:)`, `connect(pair:)`, `connectBy(leftId:rightId:)`, `disconnect()` |
| Text on the display | `sendText(_:page:pageCount:)`, `sendTeleprompter(visible:next:progress:isFirst:)` |
| Images | `sendImage(_:)` (UIImage → 1-bit 576×136), `sendImage(raw:)` (async, returns each arm's verdict), `hideImage()` |
| Dashboard | `sendDashboard(mode:subMode:)`, `sendDashboardConfig(isShow:vertical:distance:)`, `sendWeather(temperature:icon:isCelsius:)` |
| Notifications | `sendNotification(_:)`, `clearNotification(id:)` |
| Microphone | `setMicEnabled(_:)` — audio arrives as LC3 frames in `didReceiveMicAudio` |
| Settings | `setBrightness(level:auto:)`, `setSilentMode(enabled:)`, `setWearDetection(enabled:)`, `setLanguage(_:)` |
| Device state | `refreshState()`, `refreshDeviceInfo()`, `reboot()`, `factoryReset()` |

State the glasses report — battery per arm, wear state, brightness level, silent mode,
firmware, serial — is published on the SDK object, so SwiftUI can observe it directly:

```swift
@StateObject private var glasses = EvenG1SDK.shared

Text("\(glasses.batteryInfo.left)% / \(glasses.batteryInfo.right)%")
```

## Delegate

`EvenG1Delegate` reports discovery, connection changes, reconnection attempts, TouchBar
gestures (typed, `G1Touch`), incoming microphone audio, and every decoded inbound packet
(`G1Inbound`). Every method has an empty default, so you implement only what you use.

```swift
func glasses(_ sdk: EvenG1SDK, didReceiveTouch gesture: G1Touch, from side: G1Side) {
    switch gesture {
    case .singleTap:      pager.next()                 // page forward
    case .longPressBegan: sdk.setMicEnabled(true)      // Even AI capture starts
    case .longPressEnded: sdk.setMicEnabled(false)
    default: break
    }
}
```

## How the wire is driven

Each arm has its own outbox (`ArmOutbox`): writes to one arm keep a 100 ms gap, a
command for both arms goes to the left and then to the right 100 ms after the left
write actually went out, and both queues pause while an image is on the wire and drain
afterwards in order. Image packets are written with response and each arm's verdict on
the checksum is returned. None of this touches the caller's thread; the SDK is
main-thread only, like Core Bluetooth with the main queue.

Inbound packets are decoded by `G1Inbound.decode(_:)`, a pure function with its own
tests — the brightness readback, the image verdict byte and the wear-state byte are
pinned there rather than remembered.

## Protocol

The full opcode table, packet layouts, and the connection handshake are documented in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Debugging

The SDK is silent by default. To trace discovery, connection and every packet in and
out:

```swift
EvenG1SDK.isTracingEnabled = true
EvenG1SDK.traceSink = { line in myLog.append(line) }   // optional; stderr otherwise
```

## Caveats

- `sendText` writes a single page. Longer copy is truncated by the firmware — paginate
  upstream if you need more.
- The SDK is main-thread only: create it, call it and observe it from the main thread.
- Locks, garage doors, and anything safety-critical are not part of the G1 protocol; this
  package only drives the display, the microphone, and device settings.

## Credit

The protocol was pieced together from Even Realities' own demo app and the reverse
engineering community:

- [even-realities/EvenDemoApp](https://github.com/even-realities/EvenDemoApp) (Flutter)
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — `G1Constants.java`, `G1Communications.java`
- [fuutott/Even-G1-RevEng-Reference](https://github.com/fuutott/Even-G1-RevEng-Reference)
- [emingenc/even_glasses](https://github.com/emingenc/even_glasses) (Python)

Not affiliated with or endorsed by Even Realities.

## License

MIT — see [LICENSE](LICENSE).
