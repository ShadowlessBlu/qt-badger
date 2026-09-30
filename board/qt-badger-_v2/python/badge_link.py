# The hub's half of the badge: everything that talks to the STM32 sketch over
# the Bridge, plus the memory the sketch doesn't have.
#
# Why this exists as its own module: the STM32 keeps tasks, settings, the name
# tag and the destination in RAM only, so every time App Lab re-flashes the
# sketch (or the board resets) it comes up blank. The hub is the part that
# survives - it saves what the badge should look like to data/state.json and,
# whenever get_state() says "rs": 0 (fresh MCU, nothing restored), pushes it all
# back and calls mark_restored(). After that the MCU is the source of truth
# again: buttons on the badge can tick off tasks or change settings, and poll()
# copies those changes back into the saved state.
#
# Bridge facts this code is built around (learned the hard way, see the sketch):
#  - every message to the MCU is capped at 256 bytes, so one call per task,
#    chunked QR upload, compact JSON coming back;
#  - coordinates travel as decimal strings (nothing depends on how a float64
#    narrows on the MCU);
#  - never call Bridge.call() from inside a handler the MCU invoked - this
#    module only ever calls out, from the poll loop and the HTTP threads.

import json
import math
import os
import threading
import time
import unicodedata
from collections import deque

from arduino.app_utils import Bridge, Logger

logger = Logger("BadgeLink")

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # /app
DATA_DIR = os.path.join(APP_DIR, "data")
STATE_FILE = os.path.join(DATA_DIR, "state.json")

SCREEN_NAMES = ["home", "map", "peers", "tasks", "voice", "alert", "settings", "badge", "inbox"]
NAV_ACTIONS = {"left": 0, "right": 1, "select": 2, "back": 3}

MAX_TASKS = 8          # MAX_BADGE_TASKS in the sketch
MAX_MESSAGES = 5       # MAX_INBOX in the sketch
MAX_TASK_LEN = 80
MAX_MSG_LEN = 96
QR_CHUNK_BYTES = 40    # 40 bytes -> 80 hex chars per qr_data call, comfortably inside 256

DEFAULT_STATE = {
    "version": 1,
    "tasks": [],
    "settings": {"backlight": 255, "haptic": True, "peer_range_m": 3},
    # same as DEST_NAME/DEST_LAT/DEST_LON in the sketch, so the app always knows where the badge is pointing
    "destination": {"name": "Booth 12", "lat": 6.6887, "lon": -1.6243},
    "profile": {"name": "", "title": "", "org": "", "qr": None},
    "reminders": [],
    "next_reminder_id": 1,
    "config": {"tz_offset_min": 0, "api_key": ""},
}

# The badge's font is 7-bit ASCII, so anything smarter than that is folded down
# before it goes over the Bridge (the sketch drops the rest as well).
_PUNCT = {ord(k): v for k, v in {
    "‘": "'", "’": "'", "“": '"', "”": '"',
    "–": "-", "—": "-", "…": "...", " ": " ",
    "•": "-", "°": " deg ", "×": "x",
}.items()}


_UNSET = object()


class BadgeError(Exception):
    """The badge (or the Bridge to it) didn't do what was asked."""


class BadInput(ValueError):
    """The request itself is wrong - nothing was sent to the badge."""


def ascii_text(value, max_len):
    if value is None:
        return ""
    s = str(value).translate(_PUNCT)
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode("ascii")
    s = "".join(ch if ch.isprintable() else " " for ch in s)
    return " ".join(s.split())[:max_len].strip()


def haversine_m(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def _coord(value, lo, hi, what):
    try:
        v = float(value)
    except (TypeError, ValueError):
        raise BadInput(f"{what} must be a number")
    if not (lo <= v <= hi) or v != v:
        raise BadInput(f"{what} must be between {lo} and {hi}")
    return v


def _cpu_temp_c():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except Exception:
        return None


def _mem_used_pct():
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                info[k] = int(v.split()[0])
        return round(100.0 * (1 - info["MemAvailable"] / info["MemTotal"]), 1)
    except Exception:
        return None


def _disk_used_pct():
    try:
        st = os.statvfs(APP_DIR)
        return round(100.0 * (1 - st.f_bavail / st.f_blocks), 1)
    except Exception:
        return None


class BadgeLink:
    PROTOCOL = 4          # FW_PROTOCOL in the sketch: refuse to drive a sketch that speaks something else
    ARRIVE_M = 15.0       # "arrived" once this close to the destination...
    ARRIVE_RESET_M = 40.0  # ...and re-armed once this far away again
    PEER_KEEP_S = 600

    def __init__(self, on_event=None):
        self._on_event = on_event
        self._rpc_lock = threading.RLock()    # one conversation with the MCU at a time
        self._lock = threading.RLock()        # guards the cached view below
        self._save_lock = threading.Lock()
        self.saved = self._load()
        self._dirty = False
        self._last_save = 0.0

        self._state = {}          # last get_state()
        self._prev = {}           # the one before, for change detection
        self._gps = {}
        self._tasks = []          # [{"index", "text", "done"}]
        self._messages = []       # [{"index", "text", "unread"}]
        self._peers = {}          # id -> {"id","name","lat","lon","seen"}
        self._track = deque(maxlen=720)
        self._events = deque(maxlen=200)
        self._seq = 0

        self.mcu_alive = False
        self.mcu_error = "not polled yet"
        self.fw_protocol = None
        self._restore_retry_at = 0.0
        self._restored_seq = 0    # how many times we've pushed state to a fresh MCU
        self._app_alert_until = 0.0
        self._arrived_for = None
        self._last_clock_push = 0.0
        self._last_track = 0.0
        self._started = time.time()

    # ------------------------------------------------------------------ storage
    def _load(self):
        state = json.loads(json.dumps(DEFAULT_STATE))
        try:
            with open(STATE_FILE) as f:
                disk = json.load(f)
            for key, val in disk.items():
                if isinstance(val, dict) and isinstance(state.get(key), dict):
                    state[key].update(val)
                else:
                    state[key] = val
            logger.info(f"Loaded saved badge state ({len(state['tasks'])} task(s)) from {STATE_FILE}")
        except FileNotFoundError:
            logger.info("No saved badge state yet - starting fresh")
        except Exception as e:
            logger.warning(f"Couldn't read {STATE_FILE} ({e}) - starting fresh")
        return state

    def _mark_dirty(self):
        self._dirty = True

    def save_if_needed(self, force=False):
        """Write state.json (atomically) when something changed, at most about once a second."""
        if not self._dirty:
            return
        if not force and time.time() - self._last_save < 1.0:
            return
        with self._save_lock:
            try:
                os.makedirs(DATA_DIR, exist_ok=True)
                tmp = STATE_FILE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(self.saved, f, indent=1)
                os.replace(tmp, STATE_FILE)
                self._dirty = False
                self._last_save = time.time()
            except Exception as e:
                logger.error(f"Couldn't save {STATE_FILE}: {e}")

    # ---------------------------------------------------------------- Bridge I/O
    def _call(self, method, *params, timeout=4):
        with self._rpc_lock:
            try:
                return Bridge.call(method, *params, timeout=timeout)
            except (TimeoutError, ConnectionError) as e:
                raise BadgeError(f"badge not answering ({method}): {e}") from e
            except (ValueError, RuntimeError) as e:
                raise BadgeError(f"{method} failed: {e}") from e

    def _set_mcu(self, alive, error=""):
        if alive != self.mcu_alive:
            logger.info("Badge sketch is answering" if alive else f"Badge sketch not answering: {error}")
            self.mcu_alive = alive
            self._emit("link", mcu=alive)
        self.mcu_error = "" if alive else error

    def require_mcu(self):
        if not self.mcu_alive:
            raise BadgeError(self.mcu_error or "badge sketch is not running")
        if self.fw_protocol not in (None, self.PROTOCOL):
            raise BadgeError(f"the flashed sketch speaks protocol {self.fw_protocol}, this hub expects {self.PROTOCOL} - restart the app to re-flash")

    # -------------------------------------------------------------------- events
    def _emit(self, kind, **data):
        with self._lock:
            self._seq += 1
            ev = {"seq": self._seq, "t": int(time.time()), "type": kind}
            ev.update(data)
            self._events.append(ev)
        if self._on_event:
            try:
                self._on_event(ev)
            except Exception:
                pass
        return ev

    def events_after(self, seq):
        with self._lock:
            return {"latest": self._seq, "events": [e for e in self._events if e["seq"] > seq]}

    # ------------------------------------------------------------------ the poll
    def poll(self):
        """One pass of housekeeping - the main loop calls this about once a second. Never raises."""
        try:
            self._poll()
        except Exception:
            logger.exception("poll failed")
        self.save_if_needed()

    def _poll(self):
        now = time.time()
        try:
            st = json.loads(self._call("get_state", timeout=2))
        except (BadgeError, ValueError) as e:
            self._set_mcu(False, str(e))
            return
        self._set_mcu(True)

        if st.get("v") != self.PROTOCOL:
            if self.fw_protocol != st.get("v"):
                logger.error(f"Sketch protocol {st.get('v')} != hub protocol {self.PROTOCOL}: flash the matching sketch")
            self.fw_protocol = st.get("v")
            return
        self.fw_protocol = st["v"]

        with self._lock:
            self._state = st
        prev = self._prev

        if not st.get("rs"):
            # fresh MCU: nothing pushed to it yet
            if now >= self._restore_retry_at:
                self._restore()
            return

        if st["tr"] != prev.get("tr") or not prev:
            self._refresh_tasks()
        if st["mr"] != prev.get("mr") or not prev:
            self._refresh_messages()
        if prev and st["ac"] != prev.get("ac", st["ac"]):
            self._on_alert(st["ac"])
        if prev and st["vr"] != prev.get("vr", st["vr"]):
            self._on_voice()
        self._sync_settings_from_badge(st)
        self._prev = dict(st)   # its own copy: _refresh_state() updates _state in place, and must not hide a counter change from the next poll

        try:
            gps = json.loads(self._call("get_gps", timeout=2))
        except (BadgeError, ValueError):
            gps = {}
        with self._lock:
            self._gps = gps
        self._track_and_arrival(gps, now)

        if now - self._last_clock_push > 30:
            self._push_clock()
        self._fire_due_reminders(now)
        self._prune_peers(now)

    # ---------------------------------------------------------- restore / clock
    def _restore(self):
        """Push the saved badge state into a freshly reset MCU."""
        logger.info("Badge MCU is fresh - restoring saved state")
        try:
            s = self.saved
            if s["destination"]:
                d = s["destination"]
                self._call("set_destination", d["name"], f"{d['lat']:.6f}", f"{d['lon']:.6f}")
            p = s["profile"]
            if p["name"] or p["title"] or p["org"]:
                self._call("set_profile", p["name"], p["title"], p["org"])
            if p.get("qr"):
                self._push_qr(p["qr"])
            st = s["settings"]
            self._call("set_backlight", int(st["backlight"]))
            self._call("set_haptic", bool(st["haptic"]))
            self._call("set_peer_range", int(st["peer_range_m"]))
            for i, t in enumerate(s["tasks"][:MAX_TASKS]):
                self._call("add_task", t["text"])
                if t.get("done"):
                    self._call("toggle_task", i)
            self._push_clock()
            self._call("mark_restored")
            self._restored_seq += 1
            self._prev = {}
            self._emit("boot", restored=True)
        except BadgeError as e:
            logger.error(f"Restore interrupted: {e} (will retry)")
            self._restore_retry_at = time.time() + 5

    def _local_epoch(self):
        return int(time.time() + int(self.saved["config"].get("tz_offset_min", 0)) * 60)

    def _push_clock(self):
        try:
            self._call("set_clock", str(self._local_epoch()))
            self._last_clock_push = time.time()
        except BadgeError as e:
            logger.warning(f"Couldn't set the badge clock: {e}")

    def _sync_settings_from_badge(self, st):
        """Buttons on the badge can change these; keep the saved copy in step."""
        cur = self.saved["settings"]
        new = {"backlight": st["bl"], "haptic": bool(st["hp"]), "peer_range_m": st["pm"]}
        if new != {k: cur.get(k) for k in new}:
            cur.update(new)
            self._mark_dirty()

    # ------------------------------------------------------------------- reading
    # Both lists are read until the badge answers "" (past the end) rather than up to
    # the count in get_state: that count is a cached copy and can be a beat behind a
    # change made a few milliseconds ago.
    def _refresh_tasks(self):
        tasks = []
        for i in range(MAX_TASKS):
            raw = self._call("get_task", i)
            if not raw:
                break
            done, _, text = raw.partition("|")
            tasks.append({"index": i, "text": text, "done": done == "1"})
        with self._lock:
            self._tasks = tasks
        self.saved["tasks"] = [{"text": t["text"], "done": t["done"]} for t in tasks]
        self._mark_dirty()

    def _refresh_messages(self):
        msgs = []
        for i in range(MAX_MESSAGES):
            raw = self._call("get_msg", i)
            if not raw:
                break
            unread, _, text = raw.partition("|")
            msgs.append({"index": i, "text": text, "unread": unread == "1"})
        with self._lock:
            self._messages = msgs

    def _position(self):
        g = self._gps
        if g.get("fx") and "lat" in g:
            return g["lat"], g["lon"], g["fx"]
        return None

    def _track_and_arrival(self, gps, now):
        pos = self._position()
        if not pos:
            return
        lat, lon, _ = pos
        if now - self._last_track >= 5:
            self._last_track = now
            with self._lock:
                last = self._track[-1] if self._track else None
                if last is None or haversine_m(last[1], last[2], lat, lon) > 2 or now - last[0] > 30:
                    self._track.append([int(now), lat, lon])
        dist = gps.get("dst")
        d = self.saved["destination"]
        key = (d["name"], d["lat"], d["lon"]) if d else "default"
        if dist is not None:
            if dist < self.ARRIVE_M and self._arrived_for != key:
                self._arrived_for = key
                name = d["name"] if d else "destination"
                self._emit("arrived", name=name, distance_m=dist)
                try:
                    self._call("show_message", ascii_text(f"You have arrived: {name}", MAX_MSG_LEN), 2)
                except BadgeError:
                    pass
            elif dist > self.ARRIVE_RESET_M and self._arrived_for == key:
                self._arrived_for = None

    def _on_alert(self, count):
        # An alert the app asked for shows up here a moment later as a counter
        # tick, same as a button press on the badge - the window tells them apart.
        source = "app" if time.time() < self._app_alert_until else "badge"
        pos = self._position()
        ev = {"source": source, "count": count, "message": f"SOS from badge #{self._state.get('id', 1)}"}
        if pos:
            ev.update({"lat": pos[0], "lon": pos[1], "position_source": "gps" if pos[2] == 1 else "phone"})
        logger.warning(f"ALERT ({source}) - count {count}")
        self._emit("alert", **ev)

    def _on_voice(self):
        text = "no reminder right now"
        for t in self._tasks:
            if not t["done"]:
                text = t["text"]
                break
        self._emit("voice", text=text)

    # ------------------------------------------------------------- reminders
    def _fire_due_reminders(self, now):
        due = [r for r in self.saved["reminders"] if not r.get("fired") and r["at"] <= now]
        for r in due:
            r["fired"] = True
            self._mark_dirty()
            added = False
            try:
                self._call("show_message", ascii_text("Reminder: " + r["text"], MAX_MSG_LEN), 2)
                if r.get("as_task", True):
                    added = self._call("add_task", ascii_text(r["text"], MAX_TASK_LEN)) >= 0   # -1 = list full
            except BadgeError as e:
                logger.warning(f"Reminder {r['id']} fired but the badge didn't take it: {e}")
            # Re-read first, announce second: a client that reacts to the event by
            # fetching /api/tasks must see the task already there.
            self._sync_after_change()
            self._emit("reminder", id=r["id"], text=r["text"], added_as_task=added)
        # forget reminders that fired more than a day ago
        keep = [r for r in self.saved["reminders"] if not (r.get("fired") and now - r["at"] > 86400)]
        if len(keep) != len(self.saved["reminders"]):
            self.saved["reminders"] = keep
            self._mark_dirty()

    def add_reminder(self, text, at, as_task=True):
        text = ascii_text(text, MAX_TASK_LEN)
        if not text:
            raise BadInput("text is empty")
        try:
            at = float(at)
        except (TypeError, ValueError):
            raise BadInput("'at' must be a unix time in seconds")
        with self._lock:
            rid = self.saved["next_reminder_id"]
            self.saved["next_reminder_id"] = rid + 1
            r = {"id": rid, "text": text, "at": int(at), "fired": False, "as_task": bool(as_task)}
            self.saved["reminders"].append(r)
        self._mark_dirty()
        self.save_if_needed(force=True)
        return r

    def delete_reminder(self, rid):
        before = len(self.saved["reminders"])
        self.saved["reminders"] = [r for r in self.saved["reminders"] if r["id"] != rid]
        if len(self.saved["reminders"]) == before:
            raise BadInput("no such reminder")
        self._mark_dirty()
        self.save_if_needed(force=True)

    # ------------------------------------------------------------------ tasks
    def tasks(self):
        with self._lock:
            return list(self._tasks)

    def add_task(self, text):
        self.require_mcu()
        text = ascii_text(text, MAX_TASK_LEN)
        if not text:
            raise BadInput("text is empty")
        n = self._call("add_task", text)
        if n is None or n < 0:
            raise BadInput(f"the badge's task list is full ({MAX_TASKS} max) - clear some first")
        self._sync_after_change()
        return text

    def toggle_task(self, index):
        self.require_mcu()
        if not self._call("toggle_task", int(index)):
            raise BadInput("no such task")
        self._sync_after_change()

    def delete_task(self, index):
        self.require_mcu()
        if not self._call("delete_task", int(index)):
            raise BadInput("no such task")
        self._sync_after_change()

    def clear_done(self):
        self.require_mcu()
        removed = self._call("clear_done")
        self._sync_after_change()
        return removed

    def _refresh_state(self):
        """Re-read get_state right after a command, so the very next /api/status already shows its effect
        (the sketch holds the reply until it has folded the command in - see waitForFreshCaches)."""
        try:
            st = json.loads(self._call("get_state", timeout=2))
            with self._lock:
                self._state.update(st)
        except (BadgeError, ValueError) as e:
            logger.warning(f"Re-read after command failed: {e}")

    def _refresh_gps(self):
        try:
            gps = json.loads(self._call("get_gps", timeout=2))
            with self._lock:
                self._gps = gps
        except (BadgeError, ValueError) as e:
            logger.warning(f"Re-read of the position failed: {e}")

    def _sync_after_change(self):
        """Re-read the state we just changed so the HTTP reply (and state.json) is right immediately."""
        try:
            self._refresh_state()
            self._refresh_tasks()
            self._refresh_messages()
        except BadgeError as e:
            logger.warning(f"Re-read after change failed: {e}")
        self.save_if_needed(force=True)

    # --------------------------------------------------------------- messages
    def messages(self):
        with self._lock:
            return list(self._messages)

    def show_message(self, text, buzz=True, silent=False):
        self.require_mcu()
        text = ascii_text(text, MAX_MSG_LEN)
        if not text:
            raise BadInput("text is empty")
        mode = 0 if silent else (2 if buzz else 1)
        self._call("show_message", text, mode)
        self._sync_after_change()
        return text

    def delete_message(self, index):
        self.require_mcu()
        if not self._call("delete_msg", int(index)):
            raise BadInput("no such message")
        self._sync_after_change()

    def clear_messages(self):
        self.require_mcu()
        self._call("clear_msgs")
        self._sync_after_change()

    # ----------------------------------------------------------- controls
    def settings(self):
        st = self._state
        return {
            "backlight": st.get("bl", self.saved["settings"]["backlight"]),
            "haptic": bool(st.get("hp", self.saved["settings"]["haptic"])),
            "peer_range_m": st.get("pm", self.saved["settings"]["peer_range_m"]),
            "battery": st.get("bat", -1),
            "tz_offset_min": int(self.saved["config"].get("tz_offset_min", 0)),
        }

    def set_controls(self, backlight=None, haptic=None, peer_range_m=None, battery=None, tz_offset_min=None):
        self.require_mcu()
        cur = self.saved["settings"]
        if backlight is not None:
            v = int(_coord(backlight, 0, 255, "backlight"))
            self._call("set_backlight", v)
            cur["backlight"] = max(12, v)
        if haptic is not None:
            self._call("set_haptic", bool(haptic))
            cur["haptic"] = bool(haptic)
        if peer_range_m is not None:
            v = int(_coord(peer_range_m, 1, 500, "peer_range_m"))
            self._call("set_peer_range", v)
            cur["peer_range_m"] = v
        if battery is not None:
            self._call("set_battery", int(_coord(battery, -1, 100, "battery")))
        if tz_offset_min is not None:
            self.saved["config"]["tz_offset_min"] = int(_coord(tz_offset_min, -840, 840, "tz_offset_min"))
            self._push_clock()
        self._mark_dirty()
        self._sync_after_change()

    def trigger_alert(self):
        self.require_mcu()
        cooldown = self._state.get("al", 0)
        if cooldown and cooldown > 0:
            raise BadInput(f"an alert was just sent - wait {cooldown / 1000:.0f}s")
        self._app_alert_until = time.time() + 6
        self._call("trigger_alert")
        self._refresh_state()

    def find(self, seconds=30):
        self.require_mcu()
        self._call("find_badge", int(_coord(seconds, 1, 120, "seconds")))
        self._refresh_state()

    def find_stop(self):
        self.require_mcu()
        self._call("find_stop")
        self._refresh_state()

    def nav(self, action=None, screen=None):
        self.require_mcu()
        if screen is not None:
            if isinstance(screen, str):
                if screen not in SCREEN_NAMES:
                    raise BadInput(f"screen must be one of {SCREEN_NAMES}")
                screen = SCREEN_NAMES.index(screen)
            self._call("goto_screen", int(_coord(screen, 0, 8, "screen")))
        elif action == "home":
            self._call("goto_screen", 0)
        elif action in NAV_ACTIONS:
            self._call("nav", NAV_ACTIONS[action])
        else:
            raise BadInput(f"action must be one of {list(NAV_ACTIONS) + ['home']}")
        self._refresh_state()

    def voice_replay(self):
        self.require_mcu()
        self._call("voice_replay")
        self._refresh_state()

    def speak(self, text):
        """Ask the phone to read `text` out (there's no speaker on the badge)."""
        text = ascii_text(text, 200)
        if not text:
            raise BadInput("text is empty")
        self._emit("voice", text=text)

    # ------------------------------------------------- destination / position
    def destination(self):
        d = self.saved["destination"]
        return dict(d) if d else None

    def set_destination(self, name, lat, lon):
        self.require_mcu()
        lat = _coord(lat, -90, 90, "lat")
        lon = _coord(lon, -180, 180, "lon")
        name = ascii_text(name, 24) or "Destination"
        if not self._call("set_destination", name, f"{lat:.6f}", f"{lon:.6f}"):
            raise BadgeError("the badge rejected that destination")
        self._refresh_gps()
        self.saved["destination"] = {"name": name, "lat": lat, "lon": lon}
        self._arrived_for = None
        self._mark_dirty()
        self.save_if_needed(force=True)
        return self.saved["destination"]

    def set_position(self, lat, lon, accuracy=0):
        self.require_mcu()
        lat = _coord(lat, -90, 90, "lat")
        lon = _coord(lon, -180, 180, "lon")
        self._call("set_position", f"{lat:.6f}", f"{lon:.6f}", int(accuracy or 0))
        self._refresh_gps()

    # ------------------------------------------------------------------ peers
    def report_peer(self, pid, name, lat, lon):
        self.require_mcu()
        pid = int(_coord(pid, 0, 255, "id"))
        lat = _coord(lat, -90, 90, "lat")
        lon = _coord(lon, -180, 180, "lon")
        name = ascii_text(name, 10)
        self._call("peer_report", pid, name, f"{lat:.6f}", f"{lon:.6f}")
        with self._lock:
            old = self._peers.get(pid, {})
            self._peers[pid] = {"id": pid, "name": name or old.get("name", ""), "lat": lat, "lon": lon, "seen": time.time()}

    def clear_peers(self):
        self.require_mcu()
        self._call("clear_peers")
        with self._lock:
            self._peers.clear()

    def _prune_peers(self, now):
        with self._lock:
            for pid in [p for p, v in self._peers.items() if now - v["seen"] > self.PEER_KEEP_S]:
                del self._peers[pid]

    def peers(self):
        pos = self._position()
        out = []
        with self._lock:
            for p in self._peers.values():
                item = {"id": p["id"], "name": p["name"], "lat": p["lat"], "lon": p["lon"], "age_s": int(time.time() - p["seen"])}
                if pos:
                    item["distance_m"] = round(haversine_m(pos[0], pos[1], p["lat"], p["lon"]), 1)
                out.append(item)
        return sorted(out, key=lambda x: x.get("distance_m", 1e12))

    # ---------------------------------------------------------------- profile
    def profile(self):
        p = self.saved["profile"]
        return {"name": p["name"], "title": p["title"], "org": p["org"], "has_qr": bool(p.get("qr")),
                "qr_size": p["qr"]["n"] if p.get("qr") else 0}

    def set_profile(self, name=None, title=None, org=None, qr=_UNSET):
        """qr: None clears it, {"n": 33, "hex": "..."} sets it, leave out to keep the current one."""
        self.require_mcu()
        p = self.saved["profile"]
        if name is not None:
            p["name"] = ascii_text(name, 24)
        if title is not None:
            p["title"] = ascii_text(title, 32)
        if org is not None:
            p["org"] = ascii_text(org, 32)
        self._call("set_profile", p["name"], p["title"], p["org"])
        if qr is not _UNSET:
            if qr is None:
                self._call("qr_clear")
                p["qr"] = None
            else:
                n = int(qr.get("n", 0))
                hexbits = str(qr.get("hex", "")).lower()
                if not 21 <= n <= 45:
                    raise BadInput("qr.n must be between 21 and 45")
                if len(hexbits) != 2 * ((n * n + 7) // 8) or any(c not in "0123456789abcdef" for c in hexbits):
                    raise BadInput("qr.hex must be the row-major, LSB-first bit matrix as hex")
                p["qr"] = {"n": n, "hex": hexbits}
                self._push_qr(p["qr"])
        self._mark_dirty()
        self.save_if_needed(force=True)
        return self.profile()

    def _push_qr(self, qr):
        n, hexbits = qr["n"], qr["hex"]
        self._call("qr_begin", n)
        step = QR_CHUNK_BYTES * 2
        for off in range(0, len(hexbits), step):
            if not self._call("qr_data", off // 2, hexbits[off:off + step]):
                raise BadgeError("the badge refused a QR chunk")
        self._call("qr_end")

    # ---------------------------------------------------------------- read side
    def track(self):
        with self._lock:
            return list(self._track)

    def diag(self):
        """The slowest passes through the sketch's main loop (ms) since the previous call, per section.
        A healthy badge shows a few ms everywhere; a stall in loop() delays buttons, commands and redraws."""
        self.require_mcu()
        return json.loads(self._call("get_diag", timeout=3))

    def config(self):
        return self.saved["config"]

    def set_api_key(self, key):
        self.saved["config"]["api_key"] = str(key or "")
        self._mark_dirty()
        self.save_if_needed(force=True)

    def system(self):
        return {
            "cpu_temp_c": _cpu_temp_c(),
            "mem_used_pct": _mem_used_pct(),
            "disk_used_pct": _disk_used_pct(),
            "hub_uptime_s": int(time.time() - self._started),
            "host_ip": os.getenv("HOST_IP", ""),
            "restores": self._restored_seq,
        }

    def snapshot(self):
        """Everything the app draws, from the cache (no MCU round-trip)."""
        with self._lock:
            st = dict(self._state)
            gps = dict(self._gps)
            tasks = list(self._tasks)
            msgs = list(self._messages)
        scr = st.get("scr", 0)
        d = self.saved["destination"]
        gps_out = {
            "fix": gps.get("fx", 0),
            "source": {0: "none", 1: "gps", 2: "phone"}.get(gps.get("fx", 0), "none"),
            "satellites": gps.get("sat", 0),
            "hdop": gps.get("hd"),
            "speed_kmh": gps.get("spd"),
            "course": gps.get("crs"),
            "age_ms": gps.get("age"),
        }
        if "lat" in gps:
            gps_out.update({"lat": gps["lat"], "lon": gps["lon"], "distance_m": gps.get("dst"), "bearing": gps.get("brg")})
        return {
            "ok": True,
            "time": int(time.time()),
            "mcu": {"alive": self.mcu_alive, "error": self.mcu_error, "protocol": self.fw_protocol,
                    "expected_protocol": self.PROTOCOL, "restored": bool(st.get("rs")), "uptime_s": st.get("up")},
            "badge": {
                "id": st.get("id"),
                "screen": SCREEN_NAMES[scr] if 0 <= scr < len(SCREEN_NAMES) else "home",
                "selected_tile": st.get("sel"),
                "backlight": st.get("bl"),
                "haptic": bool(st.get("hp", 1)),
                "peer_range_m": st.get("pm"),
                "battery": st.get("bat", -1),
                "unread": st.get("un", 0),
                "finding": bool(st.get("fd")),
                "alert": {"count": st.get("ac", 0), "cooldown_ms": st.get("al", 0)},
            },
            "gps": gps_out,
            "destination": d,
            "tasks": tasks,
            "messages": msgs,
            "peers": self.peers(),
            "profile": self.profile(),
            "reminders": [r for r in self.saved["reminders"] if not r.get("fired")],
            "config": {"tz_offset_min": int(self.saved["config"].get("tz_offset_min", 0)),
                       "auth_required": bool(self.saved["config"].get("api_key"))},
            "hub": self.system(),
            "event_seq": self._seq,
        }
