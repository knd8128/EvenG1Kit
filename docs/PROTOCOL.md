# Even Realities G1 — BLE protocol

Everything here was derived from the vendor's own demo app and from the reverse
engineering community (see the credits in the README). It is a description of observed
behaviour, not a vendor specification: treat undocumented opcodes as unverified.

## Transport

Each temple is a **separate BLE peripheral**. Device names follow `G1_<CHANNEL>_L_<ID>`
(left, master) and `G1_<CHANNEL>_R_<ID>` (right, slave); the shared channel segment is
what pairs them.

Communication rides the Nordic UART Service:

| UUID | Role |
|------|------|
| `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | UART service |
| `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | TX — write, phone → glasses |
| `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | RX — notify, glasses → phone |

Firmware upgrade uses a separate SMP service, `8D53DC1D-1DB7-4CD3-868B-8A527460AA84`,
characteristic `DA2E7828-FBCE-4E01-AE9E-261174997C48`.

MTU is 251 bytes, leaving **180 bytes of payload** per packet. Writes are sent
`.withoutResponse`.

Commands go to the **left arm first**, then the right after roughly 100 ms; back-to-back
writes get dropped on the right side. A few commands are right-side only — the
microphone (`0x0E`) is the one that matters.

## Connection

1. Scan, and also retrieve peripherals the system already has connected.
2. Match left and right by the channel in the device name.
3. Connect both, discover the UART service, discover TX and RX.
4. Subscribe to RX notifications.
5. Send a heartbeat (`0x25 06 00 00 04`) periodically — the glasses drop the link after
   about 32 s of silence.
6. Query initial state: battery `0x2C`, brightness `0x29`, glasses state `0x2B`, wear
   detection `0x3A`, dashboard position `0x3B`, firmware `0x23 0x74`, serial `0x34`,
   MAC `0x2D`.

Responses carry a status byte: `0xC9` success, `0xCA` failure, `0xCB` more data follows.

## Opcodes

| Opcode | Name | Dir | Description |
|--------|------|-----|-------------|
| `0x01` | brightness | → | Level `0x00`–`0x2A` (0–42) plus an auto flag |
| `0x03` | silentMode | → | Enable `0x0C`, disable `0x0A` |
| `0x04` | addNotif | → | Notification app whitelist (chunked JSON) |
| `0x06` | dashMode | → | Dashboard: time/weather, calendar, stocks, news, layout, map |
| `0x07` | timer | → | Countdown display (payload format unconfirmed) |
| `0x08` | headsUpConfig | → | Head-up gesture action |
| `0x09` | teleprompter | → | Teleprompter text with progress |
| `0x0A` | navigate | → | Navigation with RLE-compressed maps |
| `0x0B` | headTilt | → | Activation angle, 0–60° |
| `0x0D` | transcribe | → | Speech-to-text control |
| `0x0E` | mic | → **right only** | Enable `0x01`, disable `0x00` |
| `0x0F` | translate | → | Translation control |
| `0x10` | headUpCalibration | → | Start `0x01`, confirm `0x02`, exit `0x03` |
| `0x15` | bmp | → | Image data chunks |
| `0x16` | bmpShow | → | CRC32 verification after upload |
| `0x17` | upgrade | → | OTA control |
| `0x18` | bmpHide | → | Hide the displayed bitmap |
| `0x1E` | notes | → | Quick notes, 4 slots |
| `0x20` | bmpComplete | → | End of image transfer: `[0x20, 0x0D, 0x0E]` |
| `0x22` | statusGet | → | Query status |
| `0x23` | firmwareInfo | → | Firmware string `0x74`, reboot `0x72`, debug log `0x6C` |
| `0x25` | heartbeat | → | Keepalive `[0x25, 0x06, 0x00, 0x00, 0x04]` |
| `0x26` | dashConfig | → | Display height (0–8), depth, show/hide, preview |
| `0x27` | wearDetection | → | Enable/disable the wear sensor |
| `0x29` | brightnessState | ← | Brightness response |
| `0x2B` | glassesState | ←→ | Byte 3: `0x06` worn, `0x07` off, `0x08` case open, `0x0B` case closed |
| `0x2C` | battery | ←→ | Frame type at byte 1, percentage at byte 2, firmware at bytes 7–9 |
| `0x2D` | macAddress | ← | MAC address |
| `0x33` | lensSerialNumber | ← | Lens serial |
| `0x34` | deviceSerialNumber | ← | Bytes 0–3 frame type (`S100` round, `S110` square), bytes 4–6 colour (`LAA` grey, `LBB` brown, `LCC` green) |
| `0x37` | uptime | ← | Time since boot |
| `0x3A` | wearDetectionGet | ← | Wear detection state |
| `0x3B` | dashPosition | ← | Dashboard position |
| `0x3D` | language | → | EN `0x00`, CN `0x01`, JP `0x02`, KR `0x03`, FR `0x04`, DE `0x05`, ES `0x06` |
| `0x47` | unpair | → | Factory reset |
| `0x4B` | notification | → | Notification payload (chunked JSON) |
| `0x4C` | notificationClear | → | Clear by msg_id, 4 bytes big-endian |
| `0x4D` | ping | → | Init / ping |
| `0x4E` | text | → | Text and AI results, paginated |
| `0x4F` | notifConfig | → | Auto-display toggle and timeout |
| `0x6E` | firmwareInfoRes | ← | Firmware version string |
| `0xF1` | micData | ← | Microphone audio, LC3, with sequence number, 30 s maximum |
| `0xF5` | device | ← | TouchBar events and state changes |
| `0xF6` | notifSetting | ← | Notification settings |

## TouchBar events (`0xF5` sub-byte)

| Sub | Event |
|-----|-------|
| `0x00` | Double tap exit — closes the current feature |
| `0x01` | Single tap — page forward/back |
| `0x04`, `0x05` | Triple tap — silent mode on/off |
| `0x06` | Worn |
| `0x07` | Removed, not in case |
| `0x08` | In case, lid open |
| `0x09` | Charging (payload `0x00`/`0x01`) |
| `0x0A` | Battery level (0–100) |
| `0x0B` | In case, lid closed |
| `0x0E` | Case charging (payload `0x00`/`0x01`) |
| `0x0F` | Case battery (0–100) |
| `0x11` | Binding success |
| `0x17` | Long press held — Even AI trigger |
| `0x18` | Long press released — Even AI stop |
| `0x1E` | Dashboard shown |
| `0x1F` | Dashboard closed |
| `0x20` | Double tap |

## Text (`0x4E`)

```
[0x4E] [seq] [totalPackets] [currentPacket] [screenStatus]
[charPosHi] [charPosLo] [pageNum] [pageCount] [UTF-8 text...]
```

`screenStatus` is `(textMode << 4) | screenAction`:

- `0x71` — text show (`0x70`) with new content (`0x01`)
- `0x31` — AI auto-scroll, new content
- `0x41` — AI complete
- `0x51` — AI manual scroll
- `0x61` — network error

The display is 488 px wide at 21 px per glyph: about 40 characters per line, 5 lines per
screen, up to 255 pages.

## Images

The panel is **576 × 136**, 1 bit per pixel.

1. Split the buffer into 174-byte chunks. The first carries a 4-byte address header:
   `[0x15, seq, 0x00, 0x1C, 0x00, 0x00] + data`; the rest are `[0x15, seq] + data`.
   The size is set by the 180-byte packet limit above, minus the six bytes the first
   chunk spends on its opcode, sequence and address — 194, which several published
   implementations use, puts that first packet at 200 bytes.
2. Send the end marker `[0x20, 0x0D, 0x0E]`.
3. Send `[0x16] + crc32`, big-endian, where the CRC-32/XZ covers the address bytes
   followed by the raw image data.

Observed on firmware 1.6.6, with the arms answering:

- The data chunks are **not** acknowledged. Nothing comes back for `0x15` at all, so the
  gap between chunks is pacing, not a wait — 60 ms is known to work.
- The end marker is answered `20 C9`.
- The CRC packet is answered `16 [crc32 big-endian] [status]`, where **`0xC9` means the
  image arrived intact and `0xCA` means it did not**. This is the only report available
  on whether a frame landed.

**Nothing else may be written while a transfer runs.** The arms take the image as a byte
stream and a command written into the middle of one becomes part of the image. An
8-second keepalive landing inside a 3-second transfer is what made the left arm answer
`0xCA` while the right, whose turn came after the beat had passed, answered `0xC9` — the
same frame, the same code, two verdicts.

## Notifications (`0x4B`)

Chunked JSON, header `[0x4B, 0x00, totalChunks, chunkIndex]` per chunk. The header eats
4 of the 180 payload bytes, so chunks hold at most 176. The glasses acknowledge each
chunk with `0xC9` before the next one should be sent.

```json
{
  "ncs_notification": {
    "msg_id": 12345, "type": 1,
    "app_identifier": "com.example.app",
    "title": "Title", "subtitle": "Sub", "message": "Body",
    "time_s": 1718045017, "date": "2025-06-10 18:43:37",
    "display_name": "App Name"
  },
  "type": "ncs_notification"
}
```

## Dashboard (`0x06`)

Sub-commands: `0x01` time/weather, `0x02` weather, `0x03` calendar (chunked), `0x04`
stocks, `0x05` news, `0x06` layout, `0x07` map.

Layouts: `0x00` full, `0x01` dual, `0x02` minimal. Secondary pane: `0x00` notes,
`0x01` stocks, `0x02` news, `0x03` calendar, `0x04` map, `0x05` empty.

The time/weather packet carries a 32-bit epoch in seconds and a 64-bit epoch in
milliseconds, a weather icon (17 values, `0x00`–`0x10`), a temperature byte, a unit flag,
and a 12/24-hour flag.

## Teleprompter (`0x09`)

```
[0x09, length, 0x00, seq, newScreen, numPackets, 0x00, partIdx, 0x00,
 completedPercent, unknown, 0x00] + text
```

`newScreen` is `0x01` on first display and `0x07` for updates. Each update sends two
packets: the visible text and the text that follows. The session ends with
`[0x09, 0x06, 0x00, seq, 0x05, 0x01]`.

## Quick notes (`0x1E`)

Four slots. Per note:

```
[0x1E, totalLen, 0x00, noteId, 0x03, 0x01, 0x00, 0x01, 0x00, noteIdx, 0x01,
 titleLen] + titleUTF8 + [textLen, 0x00] + textUTF8
```

## Even AI audio flow

1. The wearer holds the left TouchBar; the glasses send `[0xF5, 0x17]`.
2. The phone enables the microphone with `[0x0E, 0x01]` — right arm only.
3. Audio streams in as `[0xF1, seq, ...]`, LC3 encoded, up to 30 s.
4. On release the glasses send `[0xF5, 0x18]`.
5. The phone disables the microphone with `[0x0E, 0x00]`.
6. The result goes back to the display as `0x4E` text packets.

## Hardware config (`0x26`)

```
[0x26, 0x08, 0x00, seq, 0x02, preview, height (0-8), depth]
```

Sub-commands: `0x02` display, `0x04` luminance gear, `0x05` double-tap action,
`0x07` long-press action.
