# QT BADGEr _v2

A wearable name badge built on the Arduino UNO Q. The STM32 side draws the badge UI on a
320x172 ST7789 TFT and reads two buttons and a GPS; the Linux side is a hub that owns the
badge's memory, an AI schedule organizer, a JSON API and a browser dashboard; an Android
app (`qt_badger_app/`, next to this folder) remote-controls all of it over Wi-Fi.

```
 Android app ──┐                     ┌── STM32 sketch (sketch/sketch.ino)
 Browser  ─────┼─ HTTP :7000 ─ hub ──┤    TFT UI, buttons, GPS, buzzer
 Other badges' ┘  (python/)     │    └── Bridge RPC (msgpack, 256-byte messages)
                                └── data/state.json  (tasks, settings, name tag survive resets)
```

## The badge (what the TFT shows)

Two buttons: **pin 6** short = left, long = back. **Pin 4** short = right, long = select.

| Screen | What it does |
|---|---|
| **Map** | Distance, bearing and an arrow to the destination. Uses the badge's GPS, or the phone's location when the GPS has no fix. |
| **Peers** | Nearby badges/phones with distance; buzzes when one is inside the alert radius. Reports arrive through the hub. |
| **Tasks** | Up to 8 reminders. Hold 4: check off, then clear. Scrolls past 6. |
| **Voice** | Hold 4 replays the next reminder: buzzes here and the phone app reads it aloud. |
| **Alert** | Hold 4 sends an SOS (buzzer + the hub tells every connected phone). |
| **Settings** | Brightness, haptic alerts, peer alert distance. |
| **Badge** | Name tag: name, title, organisation and an optional QR code (hold 4 for a full-screen QR). |
| **Inbox** | Messages pushed from the app: a banner + buzz on arrival, then kept here (latest 5). |

The status bar shows the clock (pushed by the hub), the two button indicators, an unread-mail chip,
the hub link dot and the battery (`?` until something reports one - there's no fuel gauge on this BOM).

## Files

| Path | What it is |
|---|---|
| `sketch/sketch.ino` | STM32 firmware. Your original `.h` mock-ups are still there, untouched (they aren't compiled). |
| `python/main.py` | The hub's HTTP API (FastAPI routes registered on the WebUI brick). |
| `python/badge_link.py` | Talks to the sketch over the Bridge, polls it once a second, saves/restores its state. |
| `python/organizer.py` | AI schedule organizer: the LLM Brick as a tool-caller, with fallbacks. |
| `assets/` | Browser dashboard (open `http://<board-ip>:7000`). |
| `data/state.json` | Created at run time: tasks, settings, destination, name tag, reminders. Not in git. |

## Run it

Start **QT BADGEr _v2** from App Lab (or `arduino-app-cli app start ~/ArduinoApps/qt-badger-_v2` over SSH).
The first start compiles and flashes the sketch (a few minutes); later starts take seconds.
Then open `http://<board-ip>:7000` in a browser, or connect the Android app.

Full API reference, the Bridge protocol and troubleshooting are in `docs/` at the top of the project.

## Things worth knowing

* **The STM32 forgets everything when it resets** (RAM only). The hub notices (`"rs": 0` in `get_state`),
  pushes the saved tasks/settings/name tag back, then calls `mark_restored`. After that the badge is the
  source of truth again: ticking off a task with the buttons is copied back into `state.json`.
* **Only plain ASCII shows on the badge.** Text is folded before it's sent ("Café" becomes "Cafe").
* **Peers have no radio.** ESP-NOW needs Espressif silicon this board doesn't have, so other badges and
  phones report their position to the hub (`POST /api/peers/report`) and the hub forwards it.
* **Screen updates take about 0.3 s.** The Adafruit driver on this Zephyr core writes one pixel per SPI
  call, so a screen clear took 1.8 s. The sketch now draws into a RAM frame buffer and pushes it with bulk
  SPI transfers. `GET /api/diag` shows the slowest loop passes if anything ever feels laggy again.
* **Access key (optional).** Set `"api_key"` under `"config"` in `data/state.json`, or the `BADGE_API_KEY`
  environment variable, and every `/api/` call except `/api/health` needs an `X-Badge-Key` header.
