# Runs on the UNO Q's Linux side via Arduino App Lab.
#
# Combines three Bricks: LargeLanguageModel (schedule text -> tasks),
# Bridge (push tasks into the STM32 sketch), and WebUI (serves the
# dashboard and exposes /api/organize for the browser to call).
#
# Two independent ways now reach the badge's task list:
#  - Web Serial, straight from the browser to the STM32 sketch over USB.
#    Works even if this Python script isn't running at all.
#  - This script's /api/organize endpoint: paste a paragraph, the LLM
#    extracts action items via tool calling, each one goes to the STM32
#    through Bridge.call("add_task", text) - same provider either way.
#
# Deployment notes, confirmed the hard way while getting this working:
#  - index.html must be served BY this WebUI (put it in this project's
#    public/ folder) - opening it as a local file:// means fetch() has
#    no server to reach, and Chrome silently disables Web Serial there
#    too (it just reports "not supported" with no real explanation).
#  - Web Serial specifically needs a secure context on top of that: open
#    the dashboard at http://localhost:7000 if you're on the same
#    machine as the UNO Q. The AI Deconstructor button works fine over a
#    plain network IP (http://<device-ip>:7000), but "Connect to Badge"
#    won't until you're on localhost or you enable
#    chrome://flags/#unsafely-treat-insecure-origin-as-secure for that IP.
#  - ui.expose_api() takes the handler as a plain positional argument,
#    not a decorator - @ui.expose_api(...) throws
#    "TypeError: missing 1 required positional argument: 'function'".
#  - Still open: this board's default model (Qwen3.5-0.8B-Q4_0) is small
#    enough that it can ignore the tool and just reply with plain text
#    instead of calling add_reminder(). organize_schedule() below logs
#    the raw reply when that happens, so a genuinely empty extraction
#    shows up as a model problem in the logs rather than looking like a
#    silent Bridge/WebUI failure.

from arduino.app_bricks.llm import LargeLanguageModel, tool
from arduino.app_bricks.web_ui import WebUI
from arduino.app_utils import App, Bridge

_added = []  # tasks added during the current organize_schedule() call


@tool
def add_reminder(text: str) -> str:
    """
    Add one short, concrete reminder to the badge's task list.

    Args:
        text (str): the reminder, kept under 80 characters.

    Returns:
        str: confirmation message.
    """
    text = text.strip()[:80]
    if not text:
        return "Skipped empty reminder."
    Bridge.call("add_task", text)
    _added.append(text)
    return f"Added: {text}"


llm = LargeLanguageModel(
    system_prompt=(
        "You read schedule or agenda text and call add_reminder() once for "
        "every distinct actionable item you find - meetings, deadlines, "
        "things to pick up or check on. Keep each reminder short, concrete, "
        "and self-contained (include the time or place if the text gives "
        "one). Don't ask clarifying questions and don't add anything that "
        "isn't a real action item in the text."
    ),
    tools=[add_reminder],
    temperature=0.1,
)


def organize_schedule(paragraph: str) -> list:
    """Extract action items from `paragraph` and push each to the badge.

    Returns the list of reminder strings that were actually added.
    """
    _added.clear()
    response = llm.chat(paragraph)
    if not _added:
        # model replied without calling the tool at all - surface the raw
        # text so this reads as a model problem, not a silent Bridge/WebUI
        # failure that looks identical from the API's point of view
        print(f"[organize_schedule] no tool calls - raw reply: {response!r}")
    return list(_added)


ui = WebUI()


def api_organize(data: dict):
    paragraph = data.get("text", "")
    if not paragraph:
        return {"status": "error", "message": "No text provided", "added": []}
    added = organize_schedule(paragraph)
    if not added:
        return {
            "status": "error",
            "message": "Model didn't extract any tasks - check server logs for its raw reply",
            "added": [],
        }
    return {"status": "success", "added": added}


# Registered as a plain call, not a decorator - see the note at top.
ui.expose_api("POST", "/api/organize", api_organize)


if __name__ == "__main__":
    App.run()