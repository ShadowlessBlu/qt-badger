#!/usr/bin/env python3
"""Smoke test for the QT BADGEr hub API against a real, running badge.

    python hub_smoke_test.py [http://192.168.157.74:7000] [--key ACCESS_KEY] [--buzz]

Exercises every endpoint the Android app uses and checks what comes back, then
puts the badge back the way it found it (even if a check blows up half way).
Standard library only.

By default it stays quiet (haptics are switched off for the run: no buzzing,
and it never fires the SOS alert). --buzz also tests the buzzer paths: an
incoming-message buzz and find-my-badge.
"""
import atexit
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://192.168.157.74:7000"
KEY = ""
BUZZ = False
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--key":
        KEY = args.pop(0)
    elif a == "--buzz":
        BUZZ = True
    elif a.startswith("http"):
        BASE = a.rstrip("/")

passed = failed = 0


def call(method, path, body=None, expect=200):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if KEY:
        req.add_header("X-Badge-Key", KEY)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, text = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode()
    try:
        payload = json.loads(text) if text else None
    except ValueError:
        payload = text
    if expect is not None and status != expect:
        raise AssertionError(f"{method} {path} -> {status} (wanted {expect}): {text[:200]}")
    return payload


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


def status():
    return call("GET", "/api/status")


def wait_for(fn, timeout=8, step=0.4):
    """Poll fn() until it returns something truthy: the hub's cache lags the badge by up to ~1.3 s."""
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return None


def section(title):
    print(f"\n== {title}")


def tile():
    return status()["badge"]["selected_tile"]


def step_tile(t, d):
    return (t - 1 + d) % 8 + 1     # the home grid has 8 tiles and wraps


# --------------------------------------------------------------------------
section("health + status")
h = call("GET", "/api/health")
check("health ok, protocol 4", h["ok"] and h["protocol"] == 4, h)
check("MCU answering", h["mcu"], h)
check("MCU restored (waits for a fresh flash to be restored by the hub)", bool(wait_for(lambda: status()["mcu"]["restored"], timeout=40, step=1)))
s0 = status()
check("status has all sections", all(k in s0 for k in ("mcu", "badge", "gps", "destination", "tasks", "messages", "peers", "profile", "hub")))
orig_settings = call("GET", "/api/settings")
orig_dest = s0["destination"]
orig_profile = s0["profile"]
orig_tasks = s0["tasks"]
orig_seq = s0["event_seq"]
print(f"  (starting with {len(orig_tasks)} task(s), backlight {orig_settings['backlight']}, screen {s0['badge']['screen']})")


def cleanup():
    """Put back what the test touched. Idempotent, and never raises - it also runs after a crash."""
    steps = [
        lambda: [call("DELETE", f"/api/tasks/{i}", expect=None) for i in range(7, -1, -1)],
        lambda: call("POST", "/api/messages/clear", expect=None),
        lambda: call("POST", "/api/peers/clear", expect=None),
        lambda: call("POST", "/api/profile", {"name": orig_profile["name"], "title": orig_profile["title"], "org": orig_profile["org"], "qr": None}, expect=None),
        lambda: call("POST", "/api/destination", {"name": orig_dest["name"], "lat": orig_dest["lat"], "lon": orig_dest["lon"]}, expect=None),
        lambda: call("POST", "/api/settings", {"backlight": orig_settings["backlight"], "haptic": orig_settings["haptic"], "peer_range_m": orig_settings["peer_range_m"]}, expect=None),
        lambda: call("POST", "/api/nav", {"screen": "home"}, expect=None),
        # anything that was on the badge before comes back
        lambda: [call("POST", "/api/tasks", {"text": t["text"]}, expect=None) for t in orig_tasks],
    ]
    for s in steps:
        try:
            s()
        except Exception as e:  # noqa
            print(f"  (cleanup step failed: {e})")


atexit.register(cleanup)

# Arrival banners and reminders buzz when haptics are on; stay quiet unless --buzz.
QUIET = {"haptic": False} if not BUZZ else {}
if QUIET:
    call("POST", "/api/settings", QUIET)

# --------------------------------------------------------------------------
section("tasks")
call("POST", "/api/tasks/clear_done")
for i in range(len(call("GET", "/api/tasks")["tasks"]) - 1, -1, -1):
    call("DELETE", f"/api/tasks/{i}")
r = call("POST", "/api/tasks", {"text": "Meet Alex near stage B"})
check("add task", r["added"] == "Meet Alex near stage B" and len(r["tasks"]) == 1, r)
r = call("POST", "/api/tasks", {"text": "Café “stand” — démo \U0001F600 at 3pm"})
check("non-ASCII folded to ASCII", r["added"] == 'Cafe "stand" - demo at 3pm', r["added"])
call("POST", "/api/tasks/1/toggle")
t = call("GET", "/api/tasks")["tasks"]
check("toggle marks done", t[1]["done"] is True and t[0]["done"] is False, t)
r = call("POST", "/api/tasks/clear_done")
check("clear_done removes only the done one", r["removed"] == 1 and [x["text"] for x in r["tasks"]] == ["Meet Alex near stage B"], r)
call("DELETE", "/api/tasks/0")
check("delete task", call("GET", "/api/tasks")["tasks"] == [])
call("POST", "/api/tasks", {"text": ""}, expect=400)
check("empty text rejected (400)", True)
call("POST", "/api/tasks/99/toggle", expect=400)
check("bad index rejected (400)", True)
for i in range(12):
    r = call("POST", "/api/tasks", {"text": f"filler {i}"}, expect=None)
    if isinstance(r, dict) and "detail" in r:
        check("list-full rejected with a clear message (after 8)", i == 8 and "full" in r["detail"], (i, r))
        break
else:
    check("list-full rejected", False, "12 adds never hit the limit")
check("hub cache == what the badge reports (8 tasks)", len(status()["tasks"]) == 8 and status()["badge"] is not None)
for i in range(7, -1, -1):
    call("DELETE", f"/api/tasks/{i}")
check("all cleared", call("GET", "/api/tasks")["tasks"] == [])

# --------------------------------------------------------------------------
section("AI organizer (rules engine, background job)")
agenda = "9:00 Team stand-up in room 4. Pick up the lanyards at the desk; Call Sam about the demo at 2pm\n- Submit expense report"
job = call("POST", "/api/organize", {"text": agenda, "engine": "rules", "wait": False})
check("job accepted", job["state"] in ("running", "done") and job["job"], job)
res = wait_for(lambda: (lambda j: j if j["state"] != "running" else None)(call("GET", f"/api/organize/{job['job']}")), timeout=20)
check("job finished, engine=rules", res and res["state"] == "done" and res["engine"] == "rules", res)
check("4 reminders extracted", res and len(res["added"]) == 4, res and res["added"])
check("they are on the badge", len(call("GET", "/api/tasks")["tasks"]) == 4)
old = call("POST", "/api/organize", {"text": "Buy batteries", "engine": "rules"})
check("legacy synchronous mode still answers status=success", old.get("status") == "success", old)
check("blank text answers status=error in the legacy shape", call("POST", "/api/organize", {"text": "  ", "engine": "rules"}).get("status") == "error")
for i in range(7, -1, -1):
    call("DELETE", f"/api/tasks/{i}", expect=None)

# --------------------------------------------------------------------------
section("settings")
s = call("POST", "/api/settings", {"backlight": 200, "haptic": False, "peer_range_m": 10})
check("settings applied and read back", s["backlight"] == 200 and s["haptic"] is False and s["peer_range_m"] == 10, s)
b = wait_for(lambda: (lambda b: b if b["backlight"] == 200 and b["peer_range_m"] == 10 else None)(status()["badge"]))
check("badge reports the same values", bool(b), b)
call("POST", "/api/settings", {"backlight": 999}, expect=400)
check("out-of-range backlight rejected", True)

# --------------------------------------------------------------------------
section("messages / inbox")
r = call("POST", "/api/messages", {"text": "Coffee at 3? ☕ café by the entrance", "silent": not BUZZ, "buzz": BUZZ})
check("message accepted, ASCII-folded", r["sent"] == "Coffee at 3? cafe by the entrance", r["sent"])
m = call("GET", "/api/messages")["messages"]
check("message in the inbox, unread", len(m) == 1 and m[0]["unread"] is True, m)
check("badge counts 1 unread", bool(wait_for(lambda: status()["badge"]["unread"] == 1)))
call("DELETE", "/api/messages/0")
check("delete message", call("GET", "/api/messages")["messages"] == [])

# --------------------------------------------------------------------------
section("destination + phone position + arrival")
d = call("POST", "/api/destination", {"name": "Test Gate", "lat": 6.6900, "lon": -1.6300})
check("destination set", d["name"] == "Test Gate", d)
call("POST", "/api/position", {"lat": 6.6910, "lon": -1.6300, "accuracy": 8})
g = wait_for(lambda: (lambda s: s["gps"] if s["gps"]["fix"] == 2 and s["gps"].get("distance_m") else None)(status()), timeout=8)
check("badge uses the phone's fix (source=phone)", g and g["source"] == "phone", g)
check("distance ~111 m (0.001 deg lat)", g and 100 < g["distance_m"] < 122, g and g["distance_m"])
check("bearing ~180 (destination is south)", g and 170 < g["bearing"] < 190, g and g["bearing"])
seq_before = status()["event_seq"]
call("POST", "/api/position", {"lat": 6.69005, "lon": -1.6300, "accuracy": 5})
arrived = wait_for(lambda: [e for e in call("GET", f"/api/events?after={seq_before}")["events"] if e["type"] == "arrived"], timeout=8)
check("'arrived' event fires within 15 m", bool(arrived), arrived)
call("POST", "/api/destination", {"name": "x", "lat": 123, "lon": 0}, expect=400)
check("out-of-range latitude rejected", True)

# --------------------------------------------------------------------------
section("peers (hub as the mesh transport)")
call("POST", "/api/peers/report", {"id": 7, "name": "Alex", "lat": 6.69010, "lon": -1.63005})
call("POST", "/api/position", {"lat": 6.6900, "lon": -1.6300, "accuracy": 5})
p = wait_for(lambda: call("GET", "/api/peers")["peers"] if call("GET", "/api/peers")["peers"] and "distance_m" in call("GET", "/api/peers")["peers"][0] else None)
check("peer listed with a distance", p and len(p) == 1 and p[0]["name"] == "Alex" and 5 < p[0]["distance_m"] < 20, p)
call("POST", "/api/peers/report", {"id": 300, "lat": 0, "lon": 0}, expect=400)
check("bad peer id rejected", True)
call("POST", "/api/peers/clear")
check("peers cleared", call("GET", "/api/peers")["peers"] == [])

# --------------------------------------------------------------------------
section("name tag + QR")
n = 25
nbytes = (n * n + 7) // 8
hexbits = "".join(f"{(i * 37 + 11) & 0xFF:02x}" for i in range(nbytes))
pr = call("POST", "/api/profile", {"name": "Ama Mensah", "title": "Firmware Engineer", "org": "KNUST", "qr": {"n": n, "hex": hexbits}})
check("profile + QR accepted", pr["name"] == "Ama Mensah" and pr["has_qr"] and pr["qr_size"] == n, pr)
call("POST", "/api/profile", {"qr": {"n": 25, "hex": "00"}}, expect=400)
check("wrong-length QR rejected", True)

# --------------------------------------------------------------------------
section("remote navigation through EVERY screen (crash check)")
up0 = status()["mcu"]["uptime_s"]
for name in ("map", "peers", "tasks", "voice", "alert", "settings", "badge", "inbox", "home"):
    call("POST", "/api/nav", {"screen": name})
    check(f"goto {name}", bool(wait_for(lambda: status()["badge"]["screen"] == name, timeout=5)))
t0 = tile()
call("POST", "/api/nav", {"action": "right"})
call("POST", "/api/nav", {"action": "right"})
check("right x2 moves the highlight two tiles (wraps at 8)", bool(wait_for(lambda: tile() == step_tile(step_tile(t0, 1), 1), timeout=6)), (t0, tile()))
call("POST", "/api/nav", {"action": "left"})
check("left moves it back one", bool(wait_for(lambda: tile() == step_tile(t0, 1), timeout=6)), (t0, tile()))
call("POST", "/api/nav", {"action": "select"})
check("select opens the highlighted screen", bool(wait_for(lambda: status()["badge"]["screen"] != "home", timeout=5)))
call("POST", "/api/nav", {"action": "back"})
check("back returns home", bool(wait_for(lambda: status()["badge"]["screen"] == "home", timeout=5)))
call("POST", "/api/nav", {"screen": "nope"}, expect=400)
st = status()
check("MCU never reset while drawing all screens", st["mcu"]["alive"] and st["mcu"]["uptime_s"] >= up0, (up0, st["mcu"]["uptime_s"]))

# --------------------------------------------------------------------------
section("reminders (hub scheduler) + voice")
rem = call("POST", "/api/reminders", {"text": "Scheduled test reminder", "in_minutes": 0.05, "as_task": True})
check("reminder scheduled", rem["ok"] and rem["reminder"]["id"] > 0, rem)
check("listed as pending", any(r["id"] == rem["reminder"]["id"] for r in call("GET", "/api/reminders")["reminders"]))
fired = wait_for(lambda: [e for e in call("GET", f"/api/events?after={orig_seq}")["events"] if e["type"] == "reminder"], timeout=12)
check("reminder fired (event, added_as_task)", bool(fired) and fired[-1].get("added_as_task") is True, fired)
t = call("GET", "/api/tasks")["tasks"]
check("...and the task is already there when the event arrives", any(x["text"] == "Scheduled test reminder" for x in t), t)
check("no longer pending", not any(r["id"] == rem["reminder"]["id"] for r in call("GET", "/api/reminders")["reminders"]))
seq = status()["event_seq"]
call("POST", "/api/voice/speak", {"text": "Read me out loud"})
ev = wait_for(lambda: [e for e in call("GET", f"/api/events?after={seq}")["events"] if e["type"] == "voice"], timeout=5)
check("speak(text) -> voice event for the phone", bool(ev) and ev[0]["text"] == "Read me out loud", ev)

if BUZZ:
    section("find-my-badge, voice replay and SOS (these buzz!)")
    call("POST", "/api/find", {"seconds": 3})
    check("find running", bool(wait_for(lambda: status()["badge"]["finding"], timeout=4)))
    call("POST", "/api/find/stop")
    check("find stopped", bool(wait_for(lambda: not status()["badge"]["finding"], timeout=5)))

    call("POST", "/api/tasks", {"text": "Voice replay check"})
    open_tasks = [t["text"] for t in call("GET", "/api/tasks")["tasks"] if not t["done"]]
    seq = status()["event_seq"]
    call("POST", "/api/voice/speak", {})       # no text: what holding 4 on the Voice screen does
    ev = wait_for(lambda: [e for e in call("GET", f"/api/events?after={seq}")["events"] if e["type"] == "voice"], timeout=8)
    check("voice replay -> a 'voice' event with the FIRST open task's text", bool(ev) and ev[0]["text"] == open_tasks[0], (ev, open_tasks))
    tasks_now = call("GET", "/api/tasks")["tasks"]
    call("DELETE", f"/api/tasks/{[t['text'] for t in tasks_now].index('Voice replay check')}")

    time.sleep(6)                              # let any alert cooldown lapse
    seq = status()["event_seq"]
    call("POST", "/api/alert")
    ev = wait_for(lambda: [e for e in call("GET", f"/api/events?after={seq}")["events"] if e["type"] == "alert"], timeout=8)
    check("SOS from the app -> an 'alert' event (source=app)", bool(ev) and ev[0]["source"] == "app", ev)
    call("POST", "/api/alert", expect=400)
    check("a second SOS inside the 5 s cooldown is refused (400)", True)

# --------------------------------------------------------------------------
section("system + track")
sysinfo = call("GET", "/api/system")
check("system info", sysinfo["cpu_temp_c"] is None or sysinfo["cpu_temp_c"] > 0, sysinfo)
check("track endpoint", isinstance(call("GET", "/api/track")["points"], list))

# --------------------------------------------------------------------------
section("cleanup")
cleanup()
time.sleep(1.5)
back = call("GET", "/api/settings")
check("original settings restored", back["backlight"] == max(12, orig_settings["backlight"]) and back["haptic"] == orig_settings["haptic"], back)
end = status()
check("original tasks/profile/destination restored", [t["text"] for t in end["tasks"]] == [t["text"] for t in orig_tasks] and end["profile"]["name"] == orig_profile["name"] and end["destination"]["name"] == orig_dest["name"])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
