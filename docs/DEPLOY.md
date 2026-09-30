# Deploying, running and troubleshooting

The source of truth is `board/qt-badger-_v2/` in this folder; it is what's on the board in
`~/ArduinoApps/qt-badger-_v2/` (except `data/` and `.cache/`, which the board creates).

## Getting to the board

```bash
ssh arduino@192.168.157.74            # key-based; the board's hostname is "harold"
```

The IP changes when a phone hotspot restarts (it was `192.168.221.74` one day and `192.168.157.74` the next). Find it
again from the phone (Android app > Connection > Scan network), from the router's client list, or on the board with
`ip -br addr show wlan0`.

## Deploy a change

```bash
B=arduino@192.168.157.74:ArduinoApps/qt-badger-_v2
scp board/qt-badger-_v2/python/*.py            $B/python/
scp board/qt-badger-_v2/sketch/sketch.ino      $B/sketch/
scp board/qt-badger-_v2/assets/*               $B/assets/          # dashboard: takes effect immediately
```

* **Dashboard files (`assets/`)**: nothing to restart.
* **Python only**: restart just the hub container - the STM32 keeps running and keeps its state:
  `ssh arduino@192.168.157.74 docker restart qt-badger-_v2-main-1`
* **Sketch (or both)**: `ssh arduino@192.168.157.74 arduino-app-cli app restart ~/ArduinoApps/qt-badger-_v2`
  re-compiles, re-flashes the STM32 (it comes up blank) and restarts the containers; the hub restores the saved state.
  About 30 s when the build is cached, ~3 min from cold.

### Compile-check a sketch without flashing it

`tools/board-compile.sh` is the helper I used (copy it to the board, e.g. `~/.qtb-dev/compile.sh`, and `chmod +x`).
It mirrors what App Lab does (the `default` profile from `sketch.yaml` with the FQBN filled in) and keeps its build
directory between runs, so after the first ~3 minute build a check takes about 40 s:

```bash
scp -r board/qt-badger-_v2/sketch arduino@192.168.157.74:/tmp/stage/
ssh arduino@192.168.157.74 '~/.qtb-dev/compile.sh /tmp/stage/sketch dev; tail -5 /tmp/qtb-build/dev/compile.log'
```

The last lines show flash and RAM use (`Global variables use ... of 262144`); keep an eye on RAM now that the frame buffer
takes 110 KB of it.

## Check on it

```bash
arduino-app-cli app list                                    # status of every app
arduino-app-cli app logs user:qt-badger-_v2 --tail 50       # hub log (Python + LLM runner)
curl http://192.168.157.74:7000/api/health
python tools/hub_smoke_test.py   http://192.168.157.74:7000   # every endpoint, restores what it touched
python tools/hub_restore_test.py 192.168.157.74               # reset the badge and prove the state comes back
```

## Roll back

* Your project exactly as it was: `board/_original/qt-badger-_v2/` here, and
  `~/backups/qt-badger-_v2-original-*.tgz` on the board.
* The sketch before the frame-buffer change: `board/_backups/sketch.pre-framebuffer.ino` (copy it over
  `sketch/sketch.ino` and restart the app).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| App says "Can't reach the hub" | Wrong IP (hotspot changed): scan from the app, or `ip -br addr` on the board. Phone and board must be on the same network, and the app running in App Lab. |
| "The hub is reachable but the badge sketch is not answering" | The STM32 has no sketch or a crashed one. Restart the app from App Lab (or `arduino-app-cli app restart ...`) to re-flash. |
| "older sketch (protocol N)" | The hub was updated but the flashed sketch wasn't - restart the app to re-flash. |
| TFT is dark, hub says the badge answers | Wiring/backlight (`TFT_BL` pin 9, PWM). `POST /api/settings {"backlight": 255}`; `POST /api/find` flashes the panel. |
| Screen changes feel slow | `GET /api/diag`: `flu` should be ~280 ms, everything else in single digits. |
| Tasks vanished after a restart | They shouldn't: `data/state.json` holds them. Check `docker logs qt-badger-_v2-main-1` for "Couldn't read state.json". |
| Board disk nearly full | `df -h /`. Docker images and the LLM models are the big items; `~/.cache` and each app's `.cache/` can be cleared. |
| Compile error mentioning `MOSI`/`SCLK`/`RST` | The Adafruit_ST7796S macro clash from the old README: `sed -i 's/\bMOSI\b/mosi_pin/g; s/\bSCLK\b/sclk_pin/g; s/\bRST\b/rst_pin/g'` on that library's `.h`/`.cpp` (already applied on this board). |

## Security

The API is unauthenticated by default and open to anyone on the network the board is on. That is fine on a private
hotspot; on a shared network set an access key (see the top of `docs/API.md`). The key travels in clear text over HTTP,
so it keeps casual visitors out, it isn't protection against someone sniffing the Wi-Fi.
