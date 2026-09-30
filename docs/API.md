# QT BADGEr hub - HTTP API

The hub (`python/main.py`) serves this on **port 7000**, next to the dashboard. Everything is JSON. It is what the
Android app and the browser dashboard use, so anything they can do, a script can do.

```
GET  http://<board-ip>:7000/api/health
```

* **Errors** come back as `{"detail": "..."}` with `400` (bad input, nothing was sent to the badge), `401` (access key),
  or `503` (the hub is up but the STM32 sketch isn't answering; the body also has `"mcu": false`).
* **Access key (optional).** If `"api_key"` is set under `"config"` in `data/state.json` (or the `BADGE_API_KEY`
  environment variable), every `/api/` call except `/api/health` needs the header `X-Badge-Key: <key>`.
* **CORS** is open (`*`), so a web page from anywhere on the LAN can call it.
* **Text is ASCII-folded** before it reaches the badge (`Café` -> `Cafe`, emoji dropped) and truncated to fit:
  tasks 80 chars, messages 96, destination 24, name 24, title/organisation 32, peer name 10.
* **Timing.** `/api/status` is served from a cache the hub refreshes once a second, and after every command that
  changes what the badge shows. A command that redraws the screen returns after the badge has drawn it (~0.3 s).

## Health and state

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | `{"ok", "app":"QT BADGEr", "version", "protocol", "mcu", "auth_required", "time"}`. Always open. Used to recognise the hub when scanning a network. |
| GET | `/api/status` | Everything in one reply (below). |
| GET | `/api/events?after=<seq>` | `{"latest": n, "events": [...]}`. Events newer than `seq`. |
| GET | `/api/track` | `{"points": [[epoch, lat, lon], ...]}` - the badge's recent trail (last 720 points, ~5 s apart). |
| GET | `/api/system` | CPU temperature, memory, disk, hub uptime, host IP. |
| GET | `/api/diag` | Slowest passes through the sketch's main loop (ms) since the previous call: `tot, btn, ser, cmd, cac, tick, flu`. A healthy badge shows `flu` ~280 (a full-screen push) and everything else in single digits. |

`GET /api/status`:

```jsonc
{
  "mcu":  {"alive": true, "protocol": 4, "expected_protocol": 4, "restored": true, "uptime_s": 922, "error": ""},
  "badge": {"id": 1, "screen": "home", "selected_tile": 3, "backlight": 170, "haptic": true, "peer_range_m": 3,
            "battery": -1, "unread": 0, "finding": false, "alert": {"count": 1, "cooldown_ms": 0}},
  "gps":  {"fix": 2, "source": "phone", "satellites": 0, "hdop": 25.5, "speed_kmh": 0.0, "course": 0, "age_ms": -1,
           "lat": 6.691, "lon": -1.63, "distance_m": 111.2, "bearing": 180.0},   // lat..bearing only when there's a position
  "destination": {"name": "Booth 12", "lat": 6.6887, "lon": -1.6243},
  "tasks":    [{"index": 0, "text": "Meet Alex near stage B", "done": false}],
  "messages": [{"index": 0, "text": "Coffee at 3?", "unread": true}],
  "peers":    [{"id": 7, "name": "Alex", "lat": 6.6901, "lon": -1.63005, "age_s": 4, "distance_m": 12.4}],
  "profile":  {"name": "Ama Mensah", "title": "Firmware Engineer", "org": "KNUST", "has_qr": true, "qr_size": 25},
  "reminders": [{"id": 3, "text": "Call Sam", "at": 1790199999, "fired": false, "as_task": true}],
  "config": {"tz_offset_min": 0, "auth_required": false},
  "hub": {"cpu_temp_c": 43.4, "mem_used_pct": 23.4, "disk_used_pct": 26.4, "hub_uptime_s": 904,
          "host_ip": "192.168.157.74", "restores": 1, "llm": {"ready": false}},
  "event_seq": 4, "time": 1790195982
}
```

`gps.fix`: `0` no position, `1` the badge's own GPS, `2` the phone's location (see `/api/position`).
`badge.screen` is one of `home map peers tasks voice alert settings badge inbox`.

## Tasks (max 8 on the badge)

| Method | Path | Body | Reply |
|---|---|---|---|
| GET | `/api/tasks` | | `{"tasks": [...]}` |
| POST | `/api/tasks` | `{"text": "..."}` | `{"ok", "added", "tasks"}` - `400` when the list is full |
| POST | `/api/tasks/{index}/toggle` | | `{"ok", "tasks"}` |
| DELETE | `/api/tasks/{index}` | | `{"ok", "tasks"}` |
| POST | `/api/tasks/clear_done` | | `{"ok", "removed", "tasks"}` |

### AI organizer

`POST /api/organize` with `{"text": "...", "engine": "auto|rules|llm", "wait": false}`.

* `engine: "rules"` splits the text into lines and sentences (instant, offline). `"llm"` uses only the on-board model
  (Gemma 3 1B, roughly 4 tokens/s - expect a minute or more). `"auto"` tries the model and falls back to the rules.
* `wait: false` returns at once with `{"job": "ab12cd34", "state": "running", ...}`; poll
  `GET /api/organize/{job}` until `state` is `done` or `error`. The reply has `engine` (`llm-tool`, `llm-text` or
  `rules`), `added` (the reminders pushed), `skipped` (duplicates), `list_full`, `error`, `seconds`.
* Without `wait: false` it answers when finished, in the original shape `{"status": "success", "added": [...]}` /
  `{"status": "error", "message": "..."}`.

## Timed reminders

| Method | Path | Body |
|---|---|---|
| GET | `/api/reminders` | pending reminders |
| POST | `/api/reminders` | `{"text": "...", "at": <unix seconds>}` or `{"text": "...", "in_minutes": 10}`; optional `"as_task": true` |
| DELETE | `/api/reminders/{id}` | |

When one comes due the hub pops a banner (with a buzz, if haptics are on) on the badge, adds it as a task, and emits a
`reminder` event.

## Messages (the badge's Inbox, latest 5)

| Method | Path | Body |
|---|---|---|
| GET | `/api/messages` | |
| POST | `/api/messages` | `{"text": "...", "buzz": true, "silent": false}` - `silent` files it in the Inbox without the banner |
| DELETE | `/api/messages/{index}` | |
| POST | `/api/messages/clear` | |

## Controls

| Method | Path | Body |
|---|---|---|
| GET | `/api/settings` | -> `{"backlight", "haptic", "peer_range_m", "battery", "tz_offset_min"}` |
| POST | `/api/settings` | any of `backlight` (0-255, minimum 12), `brightness_level` (0-2), `haptic`, `peer_range_m` (1-500), `battery` (-1..100), `tz_offset_min` (-840..840) |
| POST | `/api/alert` | Sends an SOS (buzzer pattern + `alert` event). `400` during the 5 s cooldown. |
| POST | `/api/find` | `{"seconds": 30}` - flash the screen and buzz until stopped, timed out, or a button is pressed |
| POST | `/api/find/stop` | |
| POST | `/api/nav` | `{"action": "left\|right\|select\|back\|home"}` or `{"screen": "map"}` - the badge's two buttons, remotely |
| POST | `/api/voice/speak` | `{"text": "..."}` asks the phone to read it (a `voice` event); with no body it replays the current reminder (buzz + `voice` event) |

## Destination, position, peers

| Method | Path | Body |
|---|---|---|
| GET | `/api/destination` | |
| POST | `/api/destination` | `{"name": "Booth 12", "lat": 6.6887, "lon": -1.6243}` |
| POST | `/api/position` | `{"lat", "lon", "accuracy"}` - the phone's location. The badge uses it whenever its own GPS has no fix younger than 10 s; the phone should resend every few seconds (it is trusted for 30 s). |
| GET | `/api/peers` | sorted by distance |
| POST | `/api/peers/report` | `{"id": 0-255, "name": "Alex", "lat", "lon"}` |
| POST | `/api/peers/clear` | |

The hub emits an `arrived` event (and a banner on the badge) when the badge gets within 15 m of the destination, and
re-arms once it is 40 m away.

## Name tag

`GET /api/profile`, `POST /api/profile` with any of `name`, `title`, `org`, and optionally `qr`:

* omit `qr` to leave the QR code as it is; `"qr": null` removes it;
* `"qr": {"n": 25, "hex": "..."}` sets it: `n` x `n` modules, 21 <= n <= 45, as a bit matrix - **row-major, LSB first**
  (`bit = row*n + col`, 1 = dark) written as hex. `hex` must be exactly `2 * ceil(n*n / 8)` characters.

## Events

`GET /api/events?after=<seq>` (also pushed to browsers as Socket.IO `event` messages). Each has `seq`, `t` (unix
seconds) and `type`:

| type | extra fields | when |
|---|---|---|
| `alert` | `source` (`badge`/`app`), `count`, `message`, `lat`, `lon`, `position_source` (`gps`/`phone`) if there's a position | SOS pressed on the badge, or sent through `/api/alert` |
| `voice` | `text` | the Voice screen was used on the badge, or `/api/voice/speak` was called - the phone should read `text` aloud |
| `reminder` | `id`, `text`, `added_as_task` | a timed reminder fired |
| `arrived` | `name`, `distance_m` | within 15 m of the destination |
| `link` | `mcu` (bool) | the STM32 sketch stopped/started answering |
| `boot` | `restored` | the STM32 reset and the hub pushed the saved state back |

The log keeps the latest 200. `event_seq` in `/api/status` tells a client whether it needs to fetch.

## Try it

```bash
curl http://192.168.157.74:7000/api/health
curl -X POST http://192.168.157.74:7000/api/tasks -H 'Content-Type: application/json' -d '{"text":"Meet Alex near stage B"}'
curl -X POST http://192.168.157.74:7000/api/nav   -H 'Content-Type: application/json' -d '{"screen":"tasks"}'
python tools/hub_smoke_test.py http://192.168.157.74:7000     # exercises every endpoint (restores what it touched)
```
