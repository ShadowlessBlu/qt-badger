# The "AI Schedule Deconstructor": paste an agenda, get short reminders on the badge.
#
# Three engines, tried in this order, because the on-board model is tiny and slow
# (Gemma 3 1B / Qwen 0.8B on the QRB2210 reads roughly 10 tokens/s and writes
# about 4 tokens/s, so one request can take a minute):
#   "llm-tool"  the model calls add_reminder() once per action item - the
#               original design of this app
#   "llm-text"  it ignored the tool and just answered: take its bullet lines
#   "rules"     no model, or nothing usable came back: split the text into
#               sentences/lines ourselves. Instant, and works offline.
# Callers can also force one: engine="rules" skips the model entirely.
#
# Requests run as background jobs so an HTTP client (the phone) can poll instead
# of holding a connection open for a minute; the old synchronous /api/organize
# behaviour is still there via run_sync().

import re
import threading
import time
import uuid

from arduino.app_utils import Logger

from badge_link import BadInput, MAX_TASK_LEN, ascii_text

logger = Logger("Organizer")

try:
    from arduino.app_bricks.llm import LargeLanguageModel, tool
except Exception as e:  # the hub still works without the LLM brick
    LargeLanguageModel = None
    tool = None
    logger.warning(f"LLM brick unavailable ({e}) - the organizer will use its rules engine only")

SYSTEM_PROMPT = (
    "You read schedule or agenda text and call add_reminder() once for "
    "every distinct actionable item you find - meetings, deadlines, "
    "things to pick up or check on. Keep each reminder short, concrete, "
    "and self-contained (include the time or place if the text gives "
    "one). Don't ask clarifying questions and don't add anything that "
    "isn't a real action item in the text."
)

_current_job = None   # the job add_reminder() is serving; only one model request runs at a time


class _Job:
    def __init__(self, link, text, engine):
        self.id = uuid.uuid4().hex[:8]
        self.link = link
        self.text = text
        self.want = engine            # auto | llm | rules
        self.state = "running"        # running | done | error
        self.engine = None            # which engine actually produced the result
        self.added = []
        self.skipped = 0
        self.full = False             # the badge's list filled up before we ran out of items
        self.error = None
        self.raw_reply = None
        self.started = time.time()
        self.finished = None
        self.done = threading.Event()

    def add(self, text):
        """Push one reminder to the badge. Returns a message for the model."""
        text = ascii_text(text, MAX_TASK_LEN)
        if not text:
            return "Skipped empty reminder."
        low = text.lower()
        if low in {t["text"].lower() for t in self.link.tasks()} or low in {a.lower() for a in self.added}:
            self.skipped += 1
            return f"Already on the list: {text}"
        try:
            self.link.add_task(text)
        except BadInput as e:               # list full
            self.full = True
            return f"Could not add: {e}"
        self.added.append(text)
        return f"Added: {text}"

    def public(self):
        return {
            "job": self.id,
            "state": self.state,
            "engine": self.engine,
            "added": list(self.added),
            "skipped": self.skipped,
            "list_full": self.full,
            "error": self.error,
            "seconds": round((self.finished or time.time()) - self.started, 1),
        }


if tool is not None:
    @tool
    def add_reminder(text: str) -> str:
        """
        Add one short, concrete reminder to the badge's task list.

        Args:
            text (str): the reminder, kept under 80 characters.

        Returns:
            str: confirmation message.
        """
        job = _current_job
        if job is None:
            return "No active request."
        return job.add(text)
else:
    add_reminder = None


_BULLET = re.compile(r"^\s*(?:[-*•]+|\d{1,2}[.)])\s+")
_CHATTER = re.compile(r"^(sure|here|okay|ok|of course|certainly|reminders?|action items?|tasks?|schedule)\b[^\n]{0,60}:\s*$", re.I)


def _trim(s):
    s = _BULLET.sub("", s.strip()).strip(" \t.-;,")
    s = ascii_text(s, 400)
    if len(s) > MAX_TASK_LEN:
        cut = s.rfind(" ", 0, MAX_TASK_LEN - 2)
        s = (s[:cut] if cut > 30 else s[:MAX_TASK_LEN - 2]).rstrip(" ,;") + ".."
    return s


def bullet_lines(reply):
    """Bullet/numbered lines from a model's plain-text answer (chatty intros are dropped)."""
    out = []
    for raw in reply.splitlines():
        line = raw.strip()
        if not line or _CHATTER.match(line) or not _BULLET.match(line):
            continue
        item = _trim(line)
        if len(item) >= 4:
            out.append(item)
    return out


def split_rules(text):
    """No model: one reminder per line / sentence, kept short. Good enough for an agenda."""
    parts = re.split(r"[\r\n;]+|(?<=[.!?])\s+(?=[A-Z0-9])", text)
    items = []
    for p in parts:
        item = _trim(p)
        if len(item) >= 4 and item.lower() not in {i.lower() for i in items}:
            items.append(item)
    return items


class Organizer:
    def __init__(self, link):
        self.link = link
        self._llm = None
        self._llm_error = None
        self._llm_lock = threading.Lock()
        self._busy = threading.Lock()      # one model request at a time
        self._jobs = {}

    @property
    def llm_ready(self):
        return self._llm is not None

    def _get_llm(self):
        """Built on first use: the model runner can take a while, and the hub shouldn't wait for it at boot."""
        if LargeLanguageModel is None:
            return None
        with self._llm_lock:
            if self._llm is None and self._llm_error is None:
                try:
                    self._llm = LargeLanguageModel(
                        system_prompt=SYSTEM_PROMPT,
                        tools=[add_reminder],
                        temperature=0.1,
                        max_tokens=256,
                        timeout=240,
                    )
                except Exception as e:
                    self._llm_error = str(e)
                    logger.error(f"Couldn't start the LLM: {e}")
            return self._llm

    # ---------------------------------------------------------------- jobs
    def start(self, text, engine="auto"):
        text = (text or "").strip()
        if not text:
            raise BadInput("No text provided")
        if len(text) > 4000:
            raise BadInput("That's too long - keep it under 4000 characters")
        if engine not in ("auto", "llm", "rules"):
            raise BadInput("engine must be auto, llm or rules")
        job = _Job(self.link, text, engine)
        self._jobs[job.id] = job
        for old in [j for j, v in self._jobs.items() if v.finished and time.time() - v.finished > 3600]:
            del self._jobs[old]
        threading.Thread(target=self._run, args=(job,), name=f"organize-{job.id}", daemon=True).start()
        return job

    def get(self, job_id):
        job = self._jobs.get(job_id)
        if job is None:
            raise BadInput("no such job")
        return job

    def run_sync(self, text, engine="auto", timeout=300):
        job = self.start(text, engine)
        job.done.wait(timeout)
        return job

    def _finish(self, job, state, engine=None, error=None):
        job.state = state
        job.engine = engine or job.engine
        job.error = error
        job.finished = time.time()
        job.done.set()

    def _run(self, job):
        global _current_job
        try:
            if job.want in ("auto", "llm"):
                llm = self._get_llm()
                if llm is None and job.want == "llm":
                    return self._finish(job, "error", error=f"the on-board model isn't available ({self._llm_error or 'brick missing'})")
                if llm is not None and self._busy.acquire(timeout=1):
                    try:
                        _current_job = job
                        reply = llm.chat(job.text)
                        job.raw_reply = reply
                    except Exception as e:
                        logger.error(f"LLM request failed: {e}")
                        if job.want == "llm":
                            return self._finish(job, "error", error=f"model error: {e}")
                        reply = None
                    finally:
                        _current_job = None
                        self._busy.release()
                    if job.added:
                        return self._finish(job, "done", engine="llm-tool")
                    if reply:
                        lines = bullet_lines(reply)
                        if lines:
                            for line in lines:
                                if job.full:
                                    break
                                job.add(line)
                            if job.added:
                                return self._finish(job, "done", engine="llm-text")
                        logger.info(f"No usable tool calls or bullet lines - raw reply: {reply!r}")
                    if job.want == "llm":
                        return self._finish(job, "error", engine="llm", error="the model didn't extract any tasks (see hub logs for its raw reply)")
                elif job.want == "llm":
                    return self._finish(job, "error", error="the model is busy with another request")

            # rules engine (also the automatic fallback)
            for item in split_rules(job.text):
                if job.full:
                    break
                job.add(item)
            if job.added or job.skipped:
                self._finish(job, "done", engine="rules")
            else:
                self._finish(job, "error", engine="rules", error="nothing that looks like a task in that text")
        except Exception as e:
            logger.exception("organizer job crashed")
            self._finish(job, "error", error=str(e))
