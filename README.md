# QT BADGEr

A wearable event badge built on the [Arduino UNO Q](https://www.arduino.cc/) — its real-time STM32 core drives a
320×172 TFT display, two buttons, and GPS entirely on its own, while its Linux/Qualcomm side runs a hub, a REST API,
and an on-device LLM, talking to the MCU over the board's own Bridge RPC link. A companion Android app remote-controls
the whole thing over Wi-Fi.

[**Download the Android app**](https://github.com/ShadowlessBlu/qt-badger/releases/latest) · [API reference](docs/API.md) · [Bridge protocol](docs/BRIDGE.md) · [Deploy guide](docs/DEPLOY.md) · [App internals](docs/ANDROID.md)

```
 Android app (qt_badger_app/) ─┐                       ┌─ STM32 sketch: TFT badge UI, 2 buttons, GPS, buzzer
 Browser dashboard  ───────────┼─ HTTP :7000 ─  hub ───┤
 curl / scripts / other hubs ──┘             (Python)   └─ Bridge (msgpack RPC)
                                                │
                                      data/state.json  <- the STM32 forgets everything on reset; the hub doesn't
```

## What it does

Nine screens, navigated with two buttons: **Home**, **Map** (GPS waypoint navigation, distance + bearing + arrow),
**Peers** (proximity to nearby badges/phones), **Tasks** (up to 8 reminders), **Voice** (replay a reminder — buzz +
the phone reads it aloud), **Alert/SOS**, **Settings**, **Name Tag** (with a generated QR code), and **Inbox**
(messages pushed from the app, with a banner and a buzz).

The Linux side runs a persistent hub that:
- polls the STM32 over the Bridge and exposes everything as a JSON REST API (`docs/API.md`) plus a browser dashboard;
- **saves and restores badge state** — since the STM32 has no persistent memory, every re-flash or reset would
  normally wipe it; the hub keeps tasks, settings, the name tag and the destination on disk and pushes them straight
  back into a freshly-booted MCU;
- runs an **on-device LLM** (Gemma, via the board's LLM Brick) that turns a pasted or dictated agenda into structured
  reminders, with an instant offline fallback when the model is slow or busy.

The Android app mirrors the badge's own screen in real time, remote-controls its buttons, and adds what two physical
buttons can't do alone: voice dictation, a live map with the badge's GPS trail, phone-assisted positioning when the
badge has no GPS fix, one-tap SOS with emergency contacts, and the QR-code generator for the name tag.

## Why the dual-brain split matters here

The STM32 real-time core owns everything time-critical — button debouncing, the display, GPS parsing — so the badge
works as a badge with no network at all. The Qualcomm Dragonwing Linux side owns everything that needs real compute
or persistence — the hub, the API, the LLM. Neither side could do the other's job well; the project only works
because it uses both, over the Bridge link that's the point of this board's architecture.

## A performance problem worth knowing about

A remote button press originally took ~2.8 s to show up on screen. Cause: the Adafruit display driver on this Zephyr
core writes every pixel as two single-byte SPI transfers, so clearing the screen took 1.8 s on its own — every
redraw paid that cost. The sketch now renders into a RAM frame buffer and pushes it to the panel with bulk SPI
transfers instead: a full screen update is ~0.3 s, press-to-visible ~0.4 s. Details in `docs/BRIDGE.md`.

## Verified on real hardware

- Firmware compiles clean and runs on the board (208 KB / 768 KB flash, 201 KB / 256 KB RAM).
- `tools/hub_smoke_test.py`: **67/67** checks pass against the live badge — tasks, the AI organizer, settings,
  messages, destination, phone-position + arrival, peers, name tag + QR, remote navigation through all 9 screens
  with no reset, reminders, find-my-badge, voice replay, and SOS (event + cooldown).
- `tools/hub_restore_test.py`: deliberately re-flashes the STM32 blank, then confirms brightness, haptics,
  destination, the name tag + QR, and tasks (including a ticked one) all come back correctly.
- Android app: `flutter analyze` clean, 29 unit tests pass (parses a real `/api/status` reply, request shapes, error
  mapping, QR bit-packing round-trip, coordinate parsing), driven against the live badge, and installed on a real
  phone with the display, SOS, and voice replay confirmed working.
- The release APK's manifest and resources were inspected with `aapt2` — permissions, cleartext-HTTP opt-in, the
  adaptive icon, minimum Android 7.0. That inspection caught a real bug: the release build's resource shrinker was
  silently stripping the notification icon, which would have disabled every notification including SOS. Fixed with
  a keep rule and a fallback icon, then re-verified in the built APK.

## Getting started

**The board side** (`board/qt-badger-_v2/`) is an Arduino App Lab project: open it in App Lab, or use
`arduino-app-cli app start`. See `docs/DEPLOY.md` for deploying changes, restart behavior, and troubleshooting.

**The Android app** (`qt_badger_app/`):
```bash
cd qt_badger_app
flutter pub get
flutter analyze && flutter test
flutter build apk --release
```
See `docs/ANDROID.md` for the full build/permissions/architecture rundown.

## AI usage disclosure

The firmware, the Python hub, the Android app, and this documentation were developed with
[Claude](https://claude.com/claude-code) (Anthropic), an AI coding assistant, working from the project owner's
hardware, wiring, and product direction. The owner specified the features, provided and wired the physical hardware
(including the MPU6050 IMU integration), tested every feature on the physical device, and verified the AI-written
code actually works as claimed before considering anything done. All test results quoted above are real, from runs
against physical hardware — not simulated.

## Project layout

| Path | What |
|---|---|
| `board/qt-badger-_v2/` | The App Lab project deployed on the board (`sketch/`, `python/`, `assets/`, `app.yaml`). |
| `qt_badger_app/` | The Android app (Flutter). |
| `docs/` | API reference, Bridge protocol, deploy/troubleshooting guide, app internals. |
| `tools/` | Test scripts that run against the real, live badge, and a board-side compile-check helper. |
| `board/_original/` | The project exactly as it stood before this round of work, for reference. |

## License

MIT — see [`LICENSE`](LICENSE).
