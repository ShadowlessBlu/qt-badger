# Runs on the UNO Q's Linux side via Arduino App Lab.
#
# This is the badge's hub. Three pieces, one folder:
#  - badge_link.py  owns the Bridge to the STM32 sketch: it polls the badge about
#    once a second, remembers tasks/settings/name tag/destination in
#    data/state.json (the STM32 forgets everything when it resets) and pushes
#    them back into a freshly reset badge.
#  - organizer.py   the AI schedule deconstructor: LargeLanguageModel brick with
#    add_reminder() as a tool, plus two fallbacks for when the small model
#    ignores the tool or isn't up.
#  - this file      wires both into the WebUI brick: the JSON API the Android app
#    (and the browser dashboard in assets/) talks to, on port 7000.
#
# The API is documented in the README. Two things worth knowing up front:
#  - Everything under /api/ can be locked with an access key: put
#    "api_key": "something" under "config" in data/state.json (or set the
#    BADGE_API_KEY environment variable). Clients then send it as X-Badge-Key.
#    /api/health is always open so an app can tell that a key is needed.
#  - Events (SOS pressed on the badge, arrival at the destination, a "read
#    this out" request from the Voice screen, due reminders) go two ways: as
#    Socket.IO "event" messages for the dashboard, and in a short log the
#    phone reads with GET /api/events?after=<seq>.
#
# Deployment notes carried over from getting this working the first time:
#  - index.html must be served BY this WebUI (it lives in assets/) - opening it
#    as a local file:// means fetch() has no server to reach.
#  - ui.expose_api() takes the handler as a plain positional argument, not a
#    decorator - @ui.expose_api(...) throws
#    "TypeError: missing 1 required positional argument: 'function'".
#    route() below is a tiny wrapper that makes it read like a decorator.
#  - Routes must all be registered before App.run() starts the server, because
#    the static-files mount at "/" swallows anything added after it.
#  - This board's small models can ignore the tool and just reply with plain
#    text instead of calling add_reminder(); organizer.py logs the raw reply
#    when that happens and falls back to reading its bullet lines, then to a
#    rules-based splitter.

import hmac
import os
import time

from fastapi import Body
from fastapi.responses import JSONResponse
from starlette.requests import Request

from arduino.app_bricks.web_ui import WebUI
from arduino.app_utils import App, Logger

from badge_link import BadgeError, BadgeLink, BadInput
from organizer import Organizer

logger = Logger("BadgeHub")

HUB_VERSION = "2.0"

ui = WebUI()
link = BadgeLink(on_event=lambda ev: ui.send_message("event", ev))
organizer = Organizer(link)

BRIGHTNESS_LEVELS = {0: 80, 1: 170, 2: 255}   # the badge's own Low/Med/High steps


def route(method, path):
    """expose_api() as a decorator."""
    def register(fn):
        ui.expose_api(method, path, fn)
        return fn
    return register


# ----------------------------------------------------------------- access + errors
@ui.app.middleware("http")
async def require_key(request: Request, call_next):
    key = link.config().get("api_key") or os.getenv("BADGE_API_KEY", "")
    path = request.url.path
    if key and path.startswith("/api/") and path != "/api/health" and request.method != "OPTIONS":
        if not hmac.compare_digest(request.headers.get("x-badge-key", "").encode(), key.encode()):
            return JSONResponse({"detail": "missing or wrong access key"}, status_code=401)
    return await call_next(request)


@ui.app.exception_handler(BadgeError)
async def badge_error(request: Request, exc: BadgeError):
    return JSONResponse({"detail": str(exc), "mcu": link.mcu_alive}, status_code=503)


@ui.app.exception_handler(BadInput)
async def bad_input(request: Request, exc: BadInput):
    return JSONResponse({"detail": str(exc)}, status_code=400)


# ------------------------------------------------------------------ health / status
@route("GET", "/api/health")
def api_health():
    key = link.config().get("api_key") or os.getenv("BADGE_API_KEY", "")
    return {
        "ok": True,
        "app": "QT BADGEr",
        "version": HUB_VERSION,
        "protocol": BadgeLink.PROTOCOL,
        "mcu": link.mcu_alive,
        "auth_required": bool(key),
        "time": int(time.time()),
    }


@route("GET", "/api/status")
def api_status():
    snap = link.snapshot()
    snap["hub"]["llm"] = {"ready": organizer.llm_ready}
    return snap


@route("GET", "/api/events")
def api_events(after: int = 0):
    return link.events_after(after)


@route("GET", "/api/system")
def api_system():
    return link.system()


@route("GET", "/api/diag")
def api_diag():
    return link.diag()


@route("GET", "/api/track")
def api_track():
    return {"points": link.track()}


# ---------------------------------------------------------------------------- tasks
@route("GET", "/api/tasks")
def api_tasks():
    return {"tasks": link.tasks()}


@route("POST", "/api/tasks")
def api_add_task(data: dict = Body(...)):
    text = link.add_task(data.get("text", ""))
    return {"ok": True, "added": text, "tasks": link.tasks()}


@route("POST", "/api/tasks/{index}/toggle")
def api_toggle_task(index: int):
    link.toggle_task(index)
    return {"ok": True, "tasks": link.tasks()}


@route("DELETE", "/api/tasks/{index}")
def api_delete_task(index: int):
    link.delete_task(index)
    return {"ok": True, "tasks": link.tasks()}


@route("POST", "/api/tasks/clear_done")
def api_clear_done():
    removed = link.clear_done()
    return {"ok": True, "removed": removed, "tasks": link.tasks()}


# Paste a paragraph, the model (or the fallbacks) extracts action items and each
# one goes to the STM32 through Bridge.call("add_task", text). Without "wait": false
# this answers when it's done, exactly like the first version of this endpoint;
# with it the reply is immediate and the client polls /api/organize/{job}.
@route("POST", "/api/organize")
def api_organize(data: dict = Body(...)):
    text = (data.get("text") or "").strip()
    engine = data.get("engine", "auto")
    if data.get("wait") is False:
        return {"status": "running", **organizer.start(text, engine).public()}
    if not text:
        return {"status": "error", "message": "No text provided", "added": []}
    job = organizer.run_sync(text, engine)
    if job.state == "done":
        return {"status": "success", "added": job.added, "engine": job.engine, "tasks": link.tasks()}
    return {"status": "error", "message": job.error or "Model didn't extract any tasks", "added": job.added}


@route("GET", "/api/organize/{job_id}")
def api_organize_job(job_id: str):
    job = organizer.get(job_id)
    out = job.public()
    if job.state != "running":
        out["tasks"] = link.tasks()
    return out


# -------------------------------------------------------------------------- reminders
@route("GET", "/api/reminders")
def api_reminders():
    return {"reminders": [r for r in link.saved["reminders"] if not r.get("fired")]}


@route("POST", "/api/reminders")
def api_add_reminder(data: dict = Body(...)):
    at = data.get("at")
    if at is None and data.get("in_minutes") is not None:
        at = time.time() + float(data["in_minutes"]) * 60
    r = link.add_reminder(data.get("text", ""), at, as_task=data.get("as_task", True))
    return {"ok": True, "reminder": r}


@route("DELETE", "/api/reminders/{rid}")
def api_delete_reminder(rid: int):
    link.delete_reminder(rid)
    return {"ok": True}


# ---------------------------------------------------------------------------- controls
@route("GET", "/api/settings")
def api_settings():
    return link.settings()


@route("POST", "/api/settings")
def api_set_settings(data: dict = Body(...)):
    backlight = data.get("backlight")
    if backlight is None and data.get("brightness_level") is not None:
        backlight = BRIGHTNESS_LEVELS.get(int(data["brightness_level"]))
    link.set_controls(
        backlight=backlight,
        haptic=data.get("haptic"),
        peer_range_m=data.get("peer_range_m"),
        battery=data.get("battery"),
        tz_offset_min=data.get("tz_offset_min"),
    )
    return link.settings()


@route("POST", "/api/alert")
def api_alert():
    link.trigger_alert()
    return {"ok": True}


@route("POST", "/api/find")
def api_find(data: dict = Body(default={})):
    link.find(data.get("seconds", 30))
    return {"ok": True}


@route("POST", "/api/find/stop")
def api_find_stop():
    link.find_stop()
    return {"ok": True}


@route("POST", "/api/nav")
def api_nav(data: dict = Body(...)):
    link.nav(action=data.get("action"), screen=data.get("screen"))
    return {"ok": True}


@route("POST", "/api/voice/speak")
def api_speak(data: dict = Body(default={})):
    """With text: ask the phone to read it out. Without: replay the current reminder (buzz + phone reads it)."""
    if data.get("text"):
        link.speak(data["text"])
    else:
        link.voice_replay()
    return {"ok": True}


# ---------------------------------------------------------------------------- messages
@route("GET", "/api/messages")
def api_messages():
    return {"messages": link.messages()}


@route("POST", "/api/messages")
def api_send_message(data: dict = Body(...)):
    text = link.show_message(data.get("text", ""), buzz=data.get("buzz", True), silent=data.get("silent", False))
    return {"ok": True, "sent": text, "messages": link.messages()}


@route("DELETE", "/api/messages/{index}")
def api_delete_message(index: int):
    link.delete_message(index)
    return {"ok": True, "messages": link.messages()}


@route("POST", "/api/messages/clear")
def api_clear_messages():
    link.clear_messages()
    return {"ok": True}


# ----------------------------------------------------- destination / position / peers
@route("GET", "/api/destination")
def api_destination():
    return link.destination()


@route("POST", "/api/destination")
def api_set_destination(data: dict = Body(...)):
    return link.set_destination(data.get("name", ""), data.get("lat"), data.get("lon"))


@route("POST", "/api/position")
def api_position(data: dict = Body(...)):
    """The phone's location, used by the badge whenever its own GPS has no fix."""
    link.set_position(data.get("lat"), data.get("lon"), data.get("accuracy", 0))
    return {"ok": True}


@route("GET", "/api/peers")
def api_peers():
    return {"peers": link.peers()}


@route("POST", "/api/peers/report")
def api_peer_report(data: dict = Body(...)):
    link.report_peer(data.get("id"), data.get("name", ""), data.get("lat"), data.get("lon"))
    return {"ok": True, "peers": link.peers()}


@route("POST", "/api/peers/clear")
def api_peers_clear():
    link.clear_peers()
    return {"ok": True}


# -------------------------------------------------------------------------- name tag
@route("GET", "/api/profile")
def api_profile():
    return link.profile()


@route("POST", "/api/profile")
def api_set_profile(data: dict = Body(...)):
    extra = {"qr": data["qr"]} if "qr" in data else {}
    return link.set_profile(name=data.get("name"), title=data.get("title"), org=data.get("org"), **extra)


# ------------------------------------------------------------------------------ run
def loop():
    link.poll()
    time.sleep(1.0)


if __name__ == "__main__":
    App.run(user_loop=loop)
