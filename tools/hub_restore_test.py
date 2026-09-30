#!/usr/bin/env python3
"""Proves the hub restores the badge after a reset.

    python hub_restore_test.py [host] [--user arduino]

1. Sets a distinctive state through the API (brightness, haptic, peer range, destination,
   name tag + QR, three tasks with one ticked).
2. Restarts the app on the board over SSH: that re-flashes the STM32, which comes up blank.
3. Waits for the hub to notice the blank badge and push everything back, then checks it all
   matches. 4. Puts the settings you had before back.

Needs SSH key access to the board (arduino-app-cli app restart runs there). Standard library only.
"""
import json
import subprocess
import sys
import time
import urllib.request

HOST = "192.168.157.74"
USER = "arduino"
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--user":
        USER = args.pop(0)
    else:
        HOST = a
BASE = f"http://{HOST}:7000"
fails = 0


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def check(name, cond, detail=""):
    global fails
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + ("" if cond else f"  {detail}"))
    fails += 0 if cond else 1


def wait(fn, timeout, step=1.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(step)
    return None


st0 = call("GET", "/api/status")
orig = {"settings": call("GET", "/api/settings"), "dest": st0["destination"], "profile": st0["profile"], "tasks": st0["tasks"]}
print(f"before: backlight {orig['settings']['backlight']}, haptic {orig['settings']['haptic']}, {len(orig['tasks'])} task(s), destination {orig['dest']['name']!r}")

n = 25
hexbits = "".join(f"{(i * 91 + 5) & 0xFF:02x}" for i in range((n * n + 7) // 8))
print("\n== setting a distinctive state")
call("POST", "/api/settings", {"backlight": 123, "haptic": False, "peer_range_m": 25})
call("POST", "/api/destination", {"name": "Restore Test", "lat": 6.7012, "lon": -1.7034})
call("POST", "/api/profile", {"name": "Restore Tester", "title": "QA", "org": "Lab", "qr": {"n": n, "hex": hexbits}})
for i in range(7, -1, -1):
    try:
        call("DELETE", f"/api/tasks/{i}")
    except Exception:
        pass
for t in ("alpha task", "beta task", "gamma task"):
    call("POST", "/api/tasks", {"text": t})
call("POST", "/api/tasks/1/toggle")
time.sleep(2)
mid = call("GET", "/api/status")
check("state is set", mid["badge"]["backlight"] == 123 and [t["done"] for t in mid["tasks"]] == [False, True, False], mid["tasks"])

print("\n== restarting the app on the board (the STM32 comes back blank)")
t0 = time.time()
subprocess.run(["ssh", "-o", "BatchMode=yes", f"{USER}@{HOST}", "arduino-app-cli app restart ~/ArduinoApps/qt-badger-_v2 > /tmp/qtb-restore-test.log 2>&1; tail -1 /tmp/qtb-restore-test.log"], check=False, timeout=400)
print(f"   restart command finished after {time.time() - t0:.0f} s")
up = wait(lambda: call("GET", "/api/status")["mcu"]["alive"], 90)
check("badge answering again", bool(up))
res = wait(lambda: call("GET", "/api/status")["mcu"]["restored"], 60)
check("hub reports the badge restored", bool(res))
time.sleep(2)

print("\n== what came back")
st = call("GET", "/api/status")
b = st["badge"]
check("brightness 123", b["backlight"] == 123, b["backlight"])
check("haptic off", b["haptic"] is False, b["haptic"])
check("peer range 25 m", b["peer_range_m"] == 25, b["peer_range_m"])
check("destination 'Restore Test'", st["destination"]["name"] == "Restore Test" and abs(st["destination"]["lat"] - 6.7012) < 1e-6, st["destination"])
check("name tag text", (st["profile"]["name"], st["profile"]["title"], st["profile"]["org"]) == ("Restore Tester", "QA", "Lab"), st["profile"])
check("QR is on the badge", st["profile"]["has_qr"] and st["profile"]["qr_size"] == n, st["profile"])
check("3 tasks, the second one still ticked", [(t["text"], t["done"]) for t in st["tasks"]] == [("alpha task", False), ("beta task", True), ("gamma task", False)], st["tasks"])
diag = call("GET", "/api/diag")
print(f"   (loop peaks since the restart, ms: {diag})")

print("\n== putting your settings back")
for i in range(7, -1, -1):
    try:
        call("DELETE", f"/api/tasks/{i}")
    except Exception:
        pass
for t in orig["tasks"]:
    call("POST", "/api/tasks", {"text": t["text"]})
call("POST", "/api/profile", {"name": orig["profile"]["name"], "title": orig["profile"]["title"], "org": orig["profile"]["org"], "qr": None})
call("POST", "/api/destination", {"name": orig["dest"]["name"], "lat": orig["dest"]["lat"], "lon": orig["dest"]["lon"]})
call("POST", "/api/settings", {"backlight": orig["settings"]["backlight"], "haptic": orig["settings"]["haptic"], "peer_range_m": orig["settings"]["peer_range_m"]})
call("POST", "/api/nav", {"screen": "home"})
time.sleep(1.5)
back = call("GET", "/api/settings")
check("original settings back", back["backlight"] == max(12, orig["settings"]["backlight"]) and back["haptic"] == orig["settings"]["haptic"], back)

print(f"\n{'ALL PASSED' if not fails else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
