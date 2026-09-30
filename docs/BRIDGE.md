# The Bridge protocol (hub <-> STM32 sketch)

The Linux hub (`python/badge_link.py`) calls these methods on the sketch with `Bridge.call(name, *params)`.
The sketch registers them in `setup()` with `Bridge.provide(name, fn)` (`PROVIDE(...)` in `sketch.ino`).
`FW_PROTOCOL` in the sketch and `BadgeLink.PROTOCOL` in the hub must match: `get_state` reports it as `"v"` and
the hub refuses to drive a sketch that speaks a different one.

## Constraints that shaped it

* **256-byte messages.** The router caps every message to the MCU at 256 bytes, so text is sent one item per call,
  the QR bitmap in 40-byte chunks, and state comes back as compact JSON (~200 bytes).
* **Coordinates are strings** (`"6.688700"`), parsed with `atof()` on the MCU. Nothing depends on how a float64
  from Python narrows to a float on a 32-bit MCU. Text arguments are Arduino `String` (MsgPack has no `std::string`).
* **Handlers run on the bridge thread, which has a ~500-byte stack, and never touch the TFT.** They change
  mutex-guarded data, or post a small command (`postCmd`) that `loop()` executes. That keeps SPI single-threaded and
  the handlers tiny.
* **State replies are cached.** `loop()` rebuilds the `get_state`/`get_gps` JSON four times a second, and
  immediately after any command. A handler that changes something marks the caches dirty, and the next
  `get_state`/`get_gps` waits (up to 0.5 s) until `loop()` has folded the change in, so a reply is never older than
  the command that preceded it.
* **Returns**: setters return `1` (ok) or `0` (bad input) unless noted. `void` providers return nil.

## Methods

| Method | Arguments | Returns | Notes |
|---|---|---|---|
| `get_state` | - | JSON | Marks the hub as linked (`hubSeenAt`). Keys below. |
| `get_gps` | - | JSON | `fx` (0/1/2), `lat`, `lon`, `dst` (m), `brg`, `sat`, `hd`, `spd`, `crs`, `age` (ms, -1 = never). |
| `get_diag` | - | JSON | Slowest loop passes in ms since the last call: `tot btn ser cmd cac tick flu`. |
| `add_task` | text | count, or `-1` (full) | ASCII-folded, max 80 |
| `toggle_task` / `delete_task` | index | 1/0 | |
| `clear_done` | - | removed count | |
| `get_task` | index | `"<0\|1 done>\|<text>"`, `""` past the end | Read until `""`: the count in `get_state` may lag. |
| `show_message` | text, mode | inbox count | mode 0 = silent, 1 = banner, 2 = banner + buzz |
| `get_msg` | index | `"<0\|1 unread>\|<text>"`, `""` past the end | |
| `delete_msg` / `clear_msgs` | index / - | 1/0 | |
| `set_brightness` | level 0-2 | nil | the badge's Low/Med/High steps |
| `set_backlight` | pwm | 1 | 12-255 |
| `set_haptic` | bool | nil | |
| `set_peer_range` | metres | 1 | 1-500 |
| `trigger_alert` | - | nil | Queued: the 1.25 s buzzer pattern runs in `loop()`. Cooldown 5 s. |
| `voice_replay` | - | 1 | Same as holding 4 on the Voice screen. |
| `set_destination` | name, lat, lon | 1/0 | |
| `set_position` | lat, lon, accuracy_m | 1/0 | Phone-assisted fix, valid for 30 s. |
| `peer_report` | id, name, lat, lon | 1/0 | Recycles the least-recently-heard peer when all 6 slots are used. |
| `clear_peers` | - | 1 | |
| `set_profile` | name, title, org | 1 | |
| `qr_begin` | n | 1/0 | 21 <= n <= 45; clears the bitmap |
| `qr_data` | byte_offset, hex | 1/0 | `hex` = raw bytes as hex, row-major LSB-first |
| `qr_end` / `qr_clear` | - | 1/0 | |
| `nav` | 0 left, 1 right, 2 select, 3 back | 1/0 | queued |
| `goto_screen` | 0 home, 1-8 tiles | 1/0 | queued |
| `find_badge` / `find_stop` | seconds / - | 1 | |
| `set_clock` | `"<local epoch seconds>"` | 1/0 | String: too big for a small int. Local time = UTC + the hub's `tz_offset_min`. |
| `set_battery` | percent, -1 = unknown | 1 | |
| `mark_restored` | - | 1 | The hub calls this after re-pushing saved state. |

### `get_state` keys

`v` protocol, `id` badge number, `up` uptime (s), `rs` restored by the hub (0 = fresh MCU, needs a restore),
`scr` screen (0 home ... 8 inbox), `sel` highlighted tile, `bl` backlight PWM, `hp` haptic, `pm` peer radius (m),
`bat` battery (-1 unknown), `nt` task count, `tr` tasks revision, `nm` inbox count, `mr` inbox revision,
`un` unread, `np` peers, `ac` alert count (the hub watches this to notice a button-press SOS), `al` alert cooldown
left (ms), `vr` voice replays (the hub watches this to have the phone read a reminder), `fd` find-me active,
`pf` profile revision, `fx` position source.

## Screens

`0 Home, 1 Map, 2 Peers, 3 Tasks, 4 Voice, 5 Alert, 6 Settings, 7 Badge (name tag), 8 Inbox`. The Home grid highlights
tile `sel` (1-8, the same numbering minus Home).

## The display path

The Adafruit driver on this Zephyr core writes each pixel as two single-byte SPI transfers (its 32-pixel block path is
ESP32-only), so one `fillScreen` took ~1.8 s. The sketch draws into a 110 KB RGB565 frame buffer in RAM (static: the
malloc heap here is only 32 KB), through an `Adafruit_GFX` subclass so the drawing code is unchanged, and
`flushRows()` streams rows to the panel with bulk `SPI.transfer(buf, len)`. A full screen costs ~280 ms of SPI time
(the driver is interrupt-driven, ~2.5 us/byte); the status bar (24 rows) and a message banner flush only their rows.
Total sketch RAM is now ~76% of the 256 KB llext budget; if you add a big buffer, watch `Global variables use ...` in the
build output.
