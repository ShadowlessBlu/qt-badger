// Arduino UNO Qt BADGEr — badge UI (STM32 real-time core)
// v4: the hub/phone side of the badge is real now. Everything the app and the
// dashboard need goes over the Bridge (see the provider list in setup()):
// tasks (add/toggle/delete/clear/read back), an Inbox for pushed messages,
// a Name-tag screen with an optional QR code, remote settings, remote
// navigation, find-my-badge, a phone-assisted position for when the GPS has
// no sky, a settable destination, and real Peers fed by peer_report().
// The link dot and clock in the status bar are live now (hub poll + set_clock);
// the battery has no fuel gauge on this BOM, so it stays "?" until the hub or
// app pushes a number (set_battery).
//
// One rule holds the whole file together: Bridge handlers run on the bridge
// thread (500-byte stack!), loop() runs on the main thread, and the TFT/SPI is
// only ever touched from loop(). Handlers therefore only change mutex-guarded
// data or post a small command (postCmd) - loop() does the drawing, buzzing
// and anything else slow. That's also why nothing here depends on
// provide_safe() semantics.
//
// v3: Bridge wired for real — Arduino_RouterBridge confirmed against a
// working Arduino example (LED matrix + RouterBridge), including the
// separate-thread caveat that made the tasks_mtx mutex necessary.
// bridgeAddTask() is registered as "add_task" for llm_schedule_organizer.py
// to call via Bridge.call() - takes Arduino's String, not std::string;
// confirmed by an actual build failure (MsgPack's Unpacker only has
// unpack() for arduino::msgpack::str_t, i.e. String). Controls (brightness/haptic/alert) are now
// remote-settable too, via bridgeSetBrightness/bridgeSetHaptic/
// bridgeTriggerAlert - same pattern, own controls_mtx since it's separate
// state from badgeTasks[]. Map is a Pathfinder-style waypoint navigator
// (distance + bearing + arrow, math adapted from Mukesh Sankhla's
// Pathfinder project). Settings, Alert, and the local half of Peers are
// functional; the mesh transport for Peers is the hub: ESP-NOW needs
// Espressif silicon this board doesn't have, so reports arrive via
// peer_report() instead. Voice has no speaker on the BOM - replaying a
// reminder buzzes here and (v4) tells the hub, so the phone can read it out.
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>
#include <TinyGPSPlus.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <Arduino_RouterBridge.h>
#include <zephyr/kernel.h>

#define FW_PROTOCOL 4     // bumped whenever the Bridge method set changes; get_state reports it

#define TFT_CS    10
#define TFT_RST   8
#define TFT_DC    7
#define TFT_BL    9
#define VIBRATION_PIN 5   // proximity buzz for Peers - adjust to your wiring
#define BADGE_ID 1        // change per physical unit

// Two-button nav, named after the pin number (not left/right) to avoid
// exactly the kind of mismatch that caused the last bug:
//   Pin 6 - short press: move highlight left.   long press: back / cancel.
//   Pin 4 - short press: move highlight right.  long press: select.
// Wired active-LOW with INPUT_PULLUP — button's other leg goes to GND.
#define BTN_6          6
#define BTN_4          4
#define LONG_PRESS_MS  600
#define DEBOUNCE_MS    30

#define SCREEN_W 320
#define SCREEN_H 172

// ---- Display: draw into RAM, then push to the panel in a few big SPI transfers ----
// Measured on the board: on this core Adafruit_SPITFT writes every pixel as two
// single-byte SPI transfers (its 32-pixel block path is ESP32-only), so one
// fillScreen is ~110,000 transfers = about 1.8 s, and a screen change blocked
// loop() for that long. So all drawing now goes into a 110 KB RGB565 frame in RAM
// (a subclass of Adafruit_GFX - every tft.* call below is unchanged) and
// flushRows() sends it out with SPI.transfer(buf, len), one transaction per
// couple of KB. The frame is static because the malloc heap here is only 32 KB.
Adafruit_ST7789 panel = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

#define FRAME_PIXELS ((uint32_t)SCREEN_W * SCREEN_H)
static uint16_t frameBuf[FRAME_PIXELS];

class FrameBuffer : public Adafruit_GFX {
 public:
  FrameBuffer() : Adafruit_GFX(SCREEN_W, SCREEN_H) {}

  void drawPixel(int16_t x, int16_t y, uint16_t color) override {
    if ((uint16_t)x < SCREEN_W && (uint16_t)y < SCREEN_H) frameBuf[(uint32_t)y * SCREEN_W + x] = color;
  }

  void fillScreen(uint16_t color) override {
    for (uint32_t i = 0; i < FRAME_PIXELS; i++) frameBuf[i] = color;
  }

  void fillRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t color) override {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > SCREEN_W) w = SCREEN_W - x;
    if (y + h > SCREEN_H) h = SCREEN_H - y;
    if (w <= 0 || h <= 0) return;
    for (int16_t row = y; row < y + h; row++) {
      uint16_t* p = frameBuf + (uint32_t)row * SCREEN_W + x;
      for (int16_t col = 0; col < w; col++) p[col] = color;
    }
  }

  void drawFastHLine(int16_t x, int16_t y, int16_t w, uint16_t color) override { fillRect(x, y, w, 1, color); }
  void drawFastVLine(int16_t x, int16_t y, int16_t h, uint16_t color) override { fillRect(x, y, 1, h, color); }
};

FrameBuffer frame;
#define tft frame   // all the drawing code below paints the RAM frame; flushRows() puts it on the panel

#define COL_BG      ST77XX_BLACK
#define COL_TEXT    ST77XX_WHITE
#define COL_DIM     0x39C7
#define COL_ACCENT  0x07FF
#define COL_HEART   0xF800
#define COL_GOOD    0x07E0
#define COL_AMBER   0xFD20
#define COL_PURPLE  0x780F
#define COL_CORAL   0xFA45
#define COL_GOLD    0xFEA0
#define COL_SKY     0x5D9F

// ---- Hub link + battery: the two status-bar values that used to be mocks ----
// The hub polls get_state() about once a second, so "linked" simply means it
// did so within the last few seconds.
#define HUB_LINK_MS 5000
unsigned long hubSeenAt = 0;
int  batteryPct = -1;              // -1 = unknown (no fuel gauge); set_battery() fills it in
bool hubRestored = false;          // hub sets this once it has re-pushed saved state after our reset

// ---- Destination waypoint (Pathfinder-style nav) ----
// These are only the defaults now - the app/dashboard can change the
// destination at runtime with set_destination().
#define DEST_NAME "Booth 12"
#define DEST_LAT  6.68870
#define DEST_LON  -1.62430
char   destName[25] = DEST_NAME;
double destLat = DEST_LAT;
double destLon = DEST_LON;

// On UNO Q, use hardware Serial1 for pins 0 and 1.
// Legacy SoftwareSerial is not compatible.
#define gpsSerial Serial1
TinyGPSPlus gps;

enum Screen { HOME, SCR_MAP, SCR_PEERS, SCR_TASKS, SCR_VOICE, SCR_ALERT, SCR_SETTINGS, SCR_BADGE, SCR_INBOX };
const int NUM_APPS = 8;

Screen currentScreen = HOME;
int selectedTile = 1; // 1..NUM_APPS, maps onto the Screen enum (SCR_MAP=1 .. SCR_INBOX=8)

struct Tile { int x, y, w, h; uint16_t color; const char *label; };
Tile tiles[NUM_APPS] = {
  {   8,  30, 72, 62, COL_ACCENT, "Map"      },
  {  88,  30, 72, 62, COL_GOOD,   "Peers"    },
  { 168,  30, 72, 62, COL_AMBER,  "Tasks"    },
  { 248,  30, 72, 62, COL_PURPLE, "Voice"    },
  {   8, 100, 72, 62, COL_CORAL,  "Alert"    },
  {  88, 100, 72, 62, COL_DIM,    "Settings" },
  { 168, 100, 72, 62, COL_GOLD,   "Badge"    },
  { 248, 100, 72, 62, COL_SKY,    "Inbox"    },
};

// ---- Shared state ----
// Bridge handlers and loop() both touch everything below, so it's grouped by
// the mutex that guards it. tasks_mtx / controls_mtx are the two from v3;
// data_mtx covers the rest (position, destination, peers, inbox, profile, the
// command queue). k_mutex is recursive, so nested locking on one thread is fine.
K_MUTEX_DEFINE(tasks_mtx);
K_MUTEX_DEFINE(controls_mtx);
K_MUTEX_DEFINE(data_mtx);

struct Lock {
  struct k_mutex* m;
  explicit Lock(struct k_mutex* mtx) : m(mtx) { k_mutex_lock(m, K_FOREVER); }
  ~Lock() { k_mutex_unlock(m); }
};

// ---- Tasks screen: reminders assigned by the UNO Q hub ----
// Same shape as Deskbuddy's Task struct + add/toggle/delete, but there's no
// keyboard or touchscreen here, so "add" isn't a local action - the hub
// calls add_task once a reminder arrives. Browse and clear are the two things
// the wearer can do with just two buttons.
#define MAX_BADGE_TASKS 8
#define TASK_ROWS       6
struct BadgeTask { String text; bool done; };
BadgeTask badgeTasks[MAX_BADGE_TASKS];
int badgeTaskCount = 0;
int selectedBadgeTaskIdx = 0;
int taskTop = 0;                 // first visible row, so tasks 7-8 can be reached
uint16_t tasksRev = 0;           // bumped on every change: redraw trigger + the hub's cache key

// ---- Inbox: messages pushed from the app, newest first ----
#define MAX_INBOX 5
struct InboxMsg { String text; bool unread; };
InboxMsg inbox[MAX_INBOX];
int inboxCount = 0;
int selectedInboxIdx = 0;
uint16_t inboxRev = 0;

// ---- Peers: nearby badges, fed by peer_report() ----
// This file can't run ESP-NOW (STM32 core, not Espressif silicon), so the hub is
// the transport: other badges' hubs and phones POST their position to it and it
// forwards each one here. receivePeerReport() is still the single entry point.
#define MAX_PEERS 6
#define PEER_STALE_MS 120000UL
struct PeerInfo { uint8_t id; char name[11]; double lat; double lon; unsigned long lastSeen; };
PeerInfo peers[MAX_PEERS];
int peerCount = 0;
uint16_t peersRev = 0;
int peerAlertM = 3;              // proximity-buzz radius in metres (was a #define)
const int PEER_RANGES_M[4] = {3, 10, 25, 50};

// ---- Position: the badge's own GPS, plus a phone-assisted fix ----
// gps is only ever fed from loop(); handlers read gpsSnap instead so a
// half-updated TinyGPS++ never shows up as a bogus coordinate.
struct GpsSnap {
  bool valid; unsigned long at; double lat; double lon;
  int sats; float hdop; float kmph; float course; bool spdValid; bool crsValid;
};
GpsSnap gpsSnap = { false, 0, 0, 0, 0, 0, 0, 0, false, false };
#define GPS_FRESH_MS        10000UL
#define EXT_FIX_MAX_AGE_MS  30000UL
double extLat = 0, extLon = 0;   // set_position(): the phone's location, for when there's no sky
int extAccM = 0;
unsigned long extAt = 0;

struct Pos { bool fix; int src; double lat; double lon; };   // src: 0 none, 1 GPS, 2 phone
struct Dest { char name[25]; double lat; double lon; };

// ---- Settings: local device options, cycled with the same two buttons ----
// Also settable remotely (Controls page in the app), so the same
// separate-thread concern as tasks_mtx applies here too.
#define SETTINGS_ROWS 3
int settingsSelectedRow = 0;
int brightnessLevel = 2; // 0=Low 1=Med 2=High, indexes BRIGHTNESS_LEVELS
const int BRIGHTNESS_LEVELS[3] = {80, 170, 255};
int backlightPwm = 255;  // what's actually on the pin; the app can set any value, not just the 3 steps
bool hapticEnabled = true;

// ---- Alert: manual panic trigger ----
// Long-press 4 sends it, and so can the app's SOS button. Tying this
// to the IMU's fall-detection (like EchoWear's MQG-HRV/TS-HGV) instead of
// - or in addition to - a manual/remote press is a natural next step.
unsigned long alertSentAt = 0;
uint16_t alertCount = 0;         // the hub watches this to notice a press on the badge itself
#define ALERT_COOLDOWN_MS 5000

// ---- Name tag: profile text + optional QR (bit matrix pushed by the app) ----
#define QR_MAX_N     45
char profName[25]  = "";
char profTitle[33] = "";
char profOrg[33]   = "";
uint8_t qrBits[(QR_MAX_N * QR_MAX_N + 7) / 8];   // row-major, LSB first: bit = r*n + c
int  qrN = 0;
bool qrReady = false;
bool badgeQrFull = false;        // hold 4 on the Badge screen: QR fills the screen for easy scanning
uint16_t profRev = 0;

// ---- Voice: replays are counted so the hub can have the phone read them out ----
uint16_t voiceReplays = 0;

// ---- Find-my-badge ----
unsigned long findUntil = 0, findNextFlip = 0;
bool findLit = true;

// ---- Message banner overlay ----
unsigned long bannerUntil = 0;
String bannerText;

// ---- Clock: the hub pushes local time, millis() carries it between pushes ----
long clockBase = 0;              // local epoch seconds at millis()==0
bool clockSet = false;

// ---- Command queue: how bridge-thread handlers ask loop() to do UI work ----
enum CmdType { CMD_NAV, CMD_GOTO, CMD_ALERT, CMD_FIND, CMD_VOICE, CMD_REDRAW, CMD_BANNER };
struct Cmd { int type; int arg; };
#define CMD_Q_SIZE 12
Cmd cmdq[CMD_Q_SIZE];
int cmdHead = 0, cmdTail = 0;
String bannerPending;            // text for the next CMD_BANNER (latest wins)
String stateCache = "{}";        // get_state / get_gps replies, rebuilt by loop() - see buildCaches()
String gpsCache = "{}";
volatile bool cachesDirty = false;   // a handler changed something the caches show; loop() hasn't rebuilt them yet

uint32_t lastScreenSig = 0;

// ---- Loop diagnostics: the slowest pass through each part of loop(), in microseconds ----
// get_diag() reports them (in ms) and starts a fresh window. Added after the remote
// felt laggy: a stall inside loop() delays buttons, Bridge commands and redraws alike.
struct LoopStats { unsigned long total, buttons, serial, cmd, caches, tick, flush; };
LoopStats loopPeak = { 0, 0, 0, 0, 0, 0, 0 };
#define TIME_IT(field, stmt) do { unsigned long _t0 = micros(); stmt; unsigned long _d = micros() - _t0; if (_d > loopPeak.field) loopPeak.field = _d; } while (0)

bool btn6PrevRaw = HIGH, btn4PrevRaw = HIGH;
unsigned long btn6PressStart = 0, btn4PressStart = 0;
bool btn6LongFired = false, btn4LongFired = false;

// ---- button press indicator badges, top status bar ----
#define IND6_X 150
#define IND4_X 170
#define IND_Y  4
#define IND_W  14
#define IND_H  14

// ---------------- Small helpers ----------------
// (Every struct/enum above has to stay above the first function: the Arduino
// build generates function prototypes here, and they can't name a type that
// isn't declared yet.)

bool hubLinked() { return hubSeenAt != 0 && millis() - hubSeenAt < HUB_LINK_MS; }

// The default GFX font is 7-bit ASCII: anything else prints as CP437 junk, so
// every string that arrives over the Bridge goes through here first.
String asciiOnly(const String& in, unsigned int maxLen) {
  String out;
  for (unsigned int i = 0; i < in.length() && out.length() < maxLen; i++) {
    char c = in[i];
    if (c >= 32 && c <= 126) out += c;
    else if (c == '\t' || c == '\n' || c == '\r') out += ' ';
  }
  out.trim();
  return out;
}

void copyField(char* dst, size_t cap, const String& src) {
  String s = asciiOnly(src, cap - 1);
  s.toCharArray(dst, cap);
}

// FNV-1a step - screenSig() folds whatever a screen displays into one number,
// so the once-a-second tick only repaints when something visible changed
// (the old code cleared and redrew the whole panel every second: flicker).
uint32_t hashMix(uint32_t h, uint32_t v) { return (h ^ v) * 16777619u; }

// ---- command queue ----
bool postCmd(int type, int arg) {
  cachesDirty = true;                         // every command means state is about to change
  Lock l(&data_mtx);
  int next = (cmdHead + 1) % CMD_Q_SIZE;
  if (next == cmdTail) return false;          // full: drop rather than block a handler
  cmdq[cmdHead].type = type;
  cmdq[cmdHead].arg = arg;
  cmdHead = next;
  return true;
}

bool popCmd(Cmd& out) {
  Lock l(&data_mtx);
  if (cmdTail == cmdHead) return false;
  out = cmdq[cmdTail];
  cmdTail = (cmdTail + 1) % CMD_Q_SIZE;
  return true;
}

// ---- tasks ----
bool addBadgeTask(const String& text) {
  bool ok = false;
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (badgeTaskCount < MAX_BADGE_TASKS) {
    badgeTasks[badgeTaskCount].text = text;
    badgeTasks[badgeTaskCount].done = false;
    badgeTaskCount++;
    tasksRev++;
    ok = true;
  }
  k_mutex_unlock(&tasks_mtx);
  return ok;
}

bool toggleBadgeTask(int idx) {
  bool ok = false;
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (idx >= 0 && idx < badgeTaskCount) {
    badgeTasks[idx].done = !badgeTasks[idx].done;
    tasksRev++;
    ok = true;
  }
  k_mutex_unlock(&tasks_mtx);
  return ok;
}

void clampTaskSelection() {
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (selectedBadgeTaskIdx >= badgeTaskCount) selectedBadgeTaskIdx = badgeTaskCount - 1;
  if (selectedBadgeTaskIdx < 0) selectedBadgeTaskIdx = 0;
  k_mutex_unlock(&tasks_mtx);
}

bool deleteBadgeTask(int idx) {
  bool ok = false;
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (idx >= 0 && idx < badgeTaskCount) {
    for (int i = idx; i < badgeTaskCount - 1; i++) badgeTasks[i] = badgeTasks[i + 1];
    badgeTaskCount--;
    tasksRev++;
    ok = true;
  }
  k_mutex_unlock(&tasks_mtx);
  clampTaskSelection();
  return ok;
}

int clearDoneTasks() {
  int removed = 0;
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  int w = 0;
  for (int r = 0; r < badgeTaskCount; r++) {
    if (badgeTasks[r].done) { removed++; continue; }
    if (w != r) badgeTasks[w] = badgeTasks[r];
    w++;
  }
  badgeTaskCount = w;
  if (removed) tasksRev++;
  k_mutex_unlock(&tasks_mtx);
  clampTaskSelection();
  return removed;
}

// ---- inbox ----
int unreadCount() {
  Lock l(&data_mtx);
  int n = 0;
  for (int i = 0; i < inboxCount; i++) if (inbox[i].unread) n++;
  return n;
}

void markAllRead() {
  Lock l(&data_mtx);
  bool changed = false;
  for (int i = 0; i < inboxCount; i++) {
    if (inbox[i].unread) { inbox[i].unread = false; changed = true; }
  }
  if (changed) inboxRev++;
}

void pushInbox(const String& text) {
  Lock l(&data_mtx);
  for (int i = MAX_INBOX - 1; i > 0; i--) inbox[i] = inbox[i - 1];   // newest first, oldest falls off
  inbox[0].text = text;
  inbox[0].unread = true;
  if (inboxCount < MAX_INBOX) inboxCount++;
  selectedInboxIdx = 0;
  inboxRev++;
}

bool deleteInbox(int idx) {
  Lock l(&data_mtx);
  if (idx < 0 || idx >= inboxCount) return false;
  for (int i = idx; i < inboxCount - 1; i++) inbox[i] = inbox[i + 1];
  inboxCount--;
  if (selectedInboxIdx >= inboxCount) selectedInboxIdx = inboxCount - 1;
  if (selectedInboxIdx < 0) selectedInboxIdx = 0;
  inboxRev++;
  return true;
}

// ---- position ----
// One locked snapshot so lat/lon/src always belong together.
Pos currentPos() {
  Pos p = { false, 0, 0, 0 };
  Lock l(&data_mtx);
  if (gpsSnap.valid && millis() - gpsSnap.at < GPS_FRESH_MS) {
    p.fix = true; p.src = 1; p.lat = gpsSnap.lat; p.lon = gpsSnap.lon;
  } else if (extAt != 0 && millis() - extAt < EXT_FIX_MAX_AGE_MS) {
    p.fix = true; p.src = 2; p.lat = extLat; p.lon = extLon;
  }
  return p;
}

// Called from loop() each time TinyGPS++ completes a sentence.
void updateGpsSnap() {
  Lock l(&data_mtx);
  if (gps.location.isValid() && gps.location.age() < 2000) {
    gpsSnap.valid = true;
    gpsSnap.at = millis();
    gpsSnap.lat = gps.location.lat();
    gpsSnap.lon = gps.location.lng();
  }
  gpsSnap.sats = gps.satellites.isValid() ? (int)gps.satellites.value() : 0;
  gpsSnap.hdop = gps.hdop.isValid() ? gps.hdop.hdop() : 0;
  gpsSnap.spdValid = gps.speed.isValid();
  gpsSnap.kmph = gpsSnap.spdValid ? gps.speed.kmph() : 0;
  gpsSnap.crsValid = gps.course.isValid();
  gpsSnap.course = gpsSnap.crsValid ? gps.course.deg() : 0;
}

Dest getDest() {
  Dest d;
  Lock l(&data_mtx);
  strncpy(d.name, destName, sizeof(d.name));
  d.name[sizeof(d.name) - 1] = 0;
  d.lat = destLat;
  d.lon = destLon;
  return d;
}

// ---- Navigation math (distance + bearing adapted from Mukesh Sankhla's
// Pathfinder project - calculate_distance / calculate_bearing) ----
float distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  float dlat = (lat2 - lat1) * PI / 180.0;
  float dlon = (lon2 - lon1) * PI / 180.0;
  lat1 = lat1 * PI / 180.0;
  lat2 = lat2 * PI / 180.0;
  float a = sin(dlat / 2) * sin(dlat / 2) + cos(lat1) * cos(lat2) * sin(dlon / 2) * sin(dlon / 2);
  float c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return c * 6371000.0;
}

float bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  lat1 = lat1 * PI / 180.0;
  lon1 = lon1 * PI / 180.0;
  lat2 = lat2 * PI / 180.0;
  lon2 = lon2 * PI / 180.0;
  float dlon = lon2 - lon1;
  float y = sin(dlon) * cos(lat2);
  float x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon);
  float initial = atan2(y, x) * 180.0 / PI;
  return fmod(initial + 360.0, 360.0);
}

// filled triangle pointing at angleDeg (0 = up), same technique Pathfinder
// uses for its nav arrow
void drawNavArrow(int cx, int cy, int size, float angleDeg, uint16_t color) {
  float rad = angleDeg * PI / 180.0;
  int tx = cx + size * sin(rad);
  int ty = cy - size * cos(rad);
  float b1 = rad + 135.0 * PI / 180.0;
  float b2 = rad - 135.0 * PI / 180.0;
  int bx1 = cx + (size * 0.5) * sin(b1);
  int by1 = cy - (size * 0.5) * cos(b1);
  int bx2 = cx + (size * 0.5) * sin(b2);
  int by2 = cy - (size * 0.5) * cos(b2);
  tft.fillTriangle(tx, ty, bx1, by1, bx2, by2, color);
}

void buzz(uint16_t ms) {
  digitalWrite(VIBRATION_PIN, HIGH);
  delay(ms);
  digitalWrite(VIBRATION_PIN, LOW);
}

// Stand-in for real TTS: no speaker on this BOM. The buzz is the local half;
// voiceReplays tells the hub, which has the phone speak the reminder.
void announceCurrentReminder() {
  voiceReplays++;
  buzz(100);
  delay(80);
  buzz(100);
}

// ---- peers ----
void receivePeerReport(uint8_t id, const char* name, double lat, double lon) {
  Lock l(&data_mtx);
  int slot = -1;
  for (int i = 0; i < peerCount; i++) if (peers[i].id == id) { slot = i; break; }
  if (slot < 0) {
    if (peerCount < MAX_PEERS) {
      slot = peerCount++;
    } else {                                   // full: recycle the one heard from least recently
      slot = 0;
      for (int i = 1; i < peerCount; i++) if (peers[i].lastSeen < peers[slot].lastSeen) slot = i;
    }
    peers[slot].name[0] = 0;
  }
  peers[slot].id = id;
  if (name && name[0]) {
    strncpy(peers[slot].name, name, sizeof(peers[slot].name) - 1);
    peers[slot].name[sizeof(peers[slot].name) - 1] = 0;
  }
  peers[slot].lat = lat;
  peers[slot].lon = lon;
  peers[slot].lastSeen = millis();
  peersRev++;
  cachesDirty = true;
}

void receivePeerReport(uint8_t id, double lat, double lon) {
  receivePeerReport(id, "", lat, lon);
}

// ---- Settings ----
void applyBrightness() {
  analogWrite(TFT_BL, backlightPwm); // needs a PWM-capable pin
}

int nearestBrightnessLevel(int pwm) {
  int best = 0, bestDiff = 1000;
  for (int i = 0; i < 3; i++) {
    int d = abs(BRIGHTNESS_LEVELS[i] - pwm);
    if (d < bestDiff) { bestDiff = d; best = i; }
  }
  return best;
}

// Bridge provider: Bridge.call("set_brightness", level) from the app's
// Controls page. level is clamped to the same 0=Low..2=High range the
// on-device Settings screen uses.
void bridgeSetBrightness(int level) {
  k_mutex_lock(&controls_mtx, K_FOREVER);
  if (level < 0) level = 0;
  if (level > 2) level = 2;
  brightnessLevel = level;
  backlightPwm = BRIGHTNESS_LEVELS[level];
  applyBrightness();
  k_mutex_unlock(&controls_mtx);
  postCmd(CMD_REDRAW, 0);                     // the Settings screen shows the value; also marks the caches dirty
}

// Bridge provider: any backlight value, for the app's slider.
int bridgeSetBacklight(int pwm) {
  if (pwm < 12) pwm = 12;                      // never let the panel go fully dark by accident
  if (pwm > 255) pwm = 255;
  k_mutex_lock(&controls_mtx, K_FOREVER);
  backlightPwm = pwm;
  brightnessLevel = nearestBrightnessLevel(pwm);
  applyBrightness();
  k_mutex_unlock(&controls_mtx);
  postCmd(CMD_REDRAW, 0);
  return 1;
}

// Bridge provider: Bridge.call("set_haptic", enabled) from the app.
void bridgeSetHaptic(bool enabled) {
  k_mutex_lock(&controls_mtx, K_FOREVER);
  hapticEnabled = enabled;
  k_mutex_unlock(&controls_mtx);
  postCmd(CMD_REDRAW, 0);
}

int bridgeSetPeerRange(int meters) {
  if (meters < 1) meters = 1;
  if (meters > 500) meters = 500;
  k_mutex_lock(&controls_mtx, K_FOREVER);
  peerAlertM = meters;
  k_mutex_unlock(&controls_mtx);
  postCmd(CMD_REDRAW, 0);
  return 1;
}

// ---- Alert ----
void sendAlertNotification() {
  // The local half of this is real and works right now: a distinct buzzer
  // pattern, no network needed. Reaching anyone else goes through the hub:
  // it watches alertCount, and when that ticks up it tells the phone app.
  for (int i = 0; i < 5; i++) {
    digitalWrite(VIBRATION_PIN, HIGH);
    delay(150);
    digitalWrite(VIBRATION_PIN, LOW);
    delay(100);
  }
  Serial.println("ALERT triggered - local alarm fired, hub notified via alertCount");
}

unsigned long alertCooldownLeft() {
  unsigned long since = millis() - alertSentAt;
  if (alertSentAt == 0 || since >= ALERT_COOLDOWN_MS) return 0;
  return ALERT_COOLDOWN_MS - since;
}

// Shared by the button (onSelect) and the Bridge command below, so the
// cooldown check-and-set only lives in one place. The mutex only guards
// that check-and-set, not the ~1.25s buzzer sequence itself - never hold
// a lock through a long blocking call.
void triggerAlertIfReady() {
  k_mutex_lock(&controls_mtx, K_FOREVER);
  bool ready = (alertSentAt == 0) || (millis() - alertSentAt > ALERT_COOLDOWN_MS);
  if (ready) { alertSentAt = millis(); alertCount++; }
  k_mutex_unlock(&controls_mtx);
  if (ready) sendAlertNotification();
}

// ---- Clock ----
bool clockHM(int& h, int& m) {
  if (!clockSet) return false;
  long t = clockBase + (long)(millis() / 1000UL);
  long s = t % 86400L;
  if (s < 0) s += 86400L;
  h = (int)(s / 3600L);
  m = (int)((s % 3600L) / 60L);
  return true;
}

// ---- Task editor over the Serial Monitor (legacy) ----
// v2 spoke this to a Web Serial page over USB. On the UNO Q, Serial is the
// Bridge Monitor (App Lab's serial monitor / arduino-app-cli monitor), not a
// USB port, so the page couldn't reach it - the app talks to the Bridge
// providers below instead. The protocol stays because it's handy for typing
// into the serial monitor while debugging. Line-based, one message per line:
//   -> LIST                requests the current list
//   -> ADD|<text>          appends a task
//   -> TOGGLE|<index>      flips done on that task
//   -> DEL|<index>         removes that task
//   <- TASK|<index>|<0/1>|<text>   one line per task
//   <- END                         marks the end of a list dump
void sendTaskList() {
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  for (int i = 0; i < badgeTaskCount; i++) {
    Serial.print("TASK|");
    Serial.print(i);
    Serial.print("|");
    Serial.print(badgeTasks[i].done ? 1 : 0);
    Serial.print("|");
    Serial.println(badgeTasks[i].text);
  }
  k_mutex_unlock(&tasks_mtx);
  Serial.println("END");
}

void handleSerialCommand(String line) {
  line.trim();
  if (line == "LIST") {
    sendTaskList();
  } else if (line.startsWith("ADD|")) {
    addBadgeTask(asciiOnly(line.substring(4), 80));
    postCmd(CMD_REDRAW, 0);
    sendTaskList();
  } else if (line.startsWith("TOGGLE|")) {
    toggleBadgeTask(line.substring(7).toInt());
    postCmd(CMD_REDRAW, 0);
    sendTaskList();
  } else if (line.startsWith("DEL|")) {
    deleteBadgeTask(line.substring(4).toInt());
    postCmd(CMD_REDRAW, 0);
    sendTaskList();
  }
}

// Serial.available() on the Monitor is a Bridge round-trip every time it's
// asked, so poll it a few times a second instead of on every loop() pass.
void pollSerialCommands() {
  static String buf = "";
  static unsigned long lastPoll = 0;
  if (millis() - lastPoll < 250) return;
  lastPoll = millis();
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n') {
      handleSerialCommand(buf);
      buf = "";
    } else if (c != '\r') {
      buf += c;
    }
  }
}

// ---------------- Bridge providers ----------------
// Confirmed against the LED-matrix-painter example: Bridge.provide(name,
// fn) registers a sketch-side function, called from a separate thread
// than loop(). Parameter types are Arduino String / int / bool - MsgPack's
// Unpacker only knows String for text (std::string fails to build) - and
// coordinates travel as decimal strings so nothing depends on how a float64
// from Python narrows into a 32-bit float here. Requests are capped at 256
// bytes by the router, so everything below is deliberately small: one call
// per task, chunked QR upload, compact JSON for state.
//
// Handlers return 1 on success and 0 on bad input unless noted; they never
// draw - they post a command and loop() does the work.

// add_task returns the new count, or -1 when the list is full.
int bridgeAddTask(String text) {
  text = asciiOnly(text, 80);
  if (text.length() == 0) return -1;
  bool ok = addBadgeTask(text);
  postCmd(CMD_REDRAW, 0);
  return ok ? badgeTaskCount : -1;
}

int bridgeToggleTask(int idx) {
  bool ok = toggleBadgeTask(idx);
  postCmd(CMD_REDRAW, 0);
  return ok ? 1 : 0;
}

int bridgeDeleteTask(int idx) {
  bool ok = deleteBadgeTask(idx);
  postCmd(CMD_REDRAW, 0);
  return ok ? 1 : 0;
}

int bridgeClearDone() {
  int removed = clearDoneTasks();
  postCmd(CMD_REDRAW, 0);
  return removed;
}

// get_task(i) -> "<0|1>|<text>", or "" when i is out of range.
String bridgeGetTask(int idx) {
  String out = "";
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (idx >= 0 && idx < badgeTaskCount) {
    out = String(badgeTasks[idx].done ? 1 : 0) + "|" + badgeTasks[idx].text;
  }
  k_mutex_unlock(&tasks_mtx);
  return out;
}

// get_msg(i) -> "<0|1 unread>|<text>", or "" when i is out of range.
String bridgeGetMsg(int idx) {
  Lock l(&data_mtx);
  if (idx < 0 || idx >= inboxCount) return "";
  return String(inbox[idx].unread ? 1 : 0) + "|" + inbox[idx].text;
}

// mode: 0 = drop into the Inbox silently, 1 = also pop the banner, 2 = banner + buzz.
int bridgeShowMessage(String text, int mode) {
  text = asciiOnly(text, 96);
  if (text.length() == 0) return 0;
  pushInbox(text);
  if (mode >= 1) {
    { Lock l(&data_mtx); bannerPending = text; }
    postCmd(CMD_BANNER, mode >= 2 ? 1 : 0);
  } else {
    postCmd(CMD_REDRAW, 0);
  }
  return inboxCount;
}

int bridgeDeleteMsg(int idx) {
  bool ok = deleteInbox(idx);
  postCmd(CMD_REDRAW, 0);
  return ok ? 1 : 0;
}

int bridgeClearMsgs() {
  {
    Lock l(&data_mtx);
    inboxCount = 0;
    selectedInboxIdx = 0;
    inboxRev++;
  }
  postCmd(CMD_REDRAW, 0);
  return 1;
}

// set_destination(name, lat, lon) - coordinates as decimal strings.
int bridgeSetDestination(String name, String lat, String lon) {
  double la = atof(lat.c_str());
  double lo = atof(lon.c_str());
  if (la < -90.0 || la > 90.0 || lo < -180.0 || lo > 180.0) return 0;
  String clean = asciiOnly(name, sizeof(destName) - 1);
  if (clean.length() == 0) clean = "Destination";
  {
    Lock l(&data_mtx);
    clean.toCharArray(destName, sizeof(destName));
    destLat = la;
    destLon = lo;
  }
  postCmd(CMD_REDRAW, 0);
  return 1;
}

// set_position(lat, lon, accuracy_m) - the phone's location, used whenever the
// badge's own GPS has no fresh fix. The app refreshes it every few seconds.
int bridgeSetPosition(String lat, String lon, int accuracyM) {
  double la = atof(lat.c_str());
  double lo = atof(lon.c_str());
  if (la < -90.0 || la > 90.0 || lo < -180.0 || lo > 180.0) return 0;
  {
    Lock l(&data_mtx);
    extLat = la;
    extLon = lo;
    extAccM = accuracyM;
    extAt = millis();
  }
  cachesDirty = true;                         // get_gps reports the phone fix + distance/bearing
  return 1;
}

// peer_report(id, name, lat, lon) - the hub's stand-in for the mesh transport.
int bridgePeerReport(int id, String name, String lat, String lon) {
  if (id < 0 || id > 255) return 0;
  double la = atof(lat.c_str());
  double lo = atof(lon.c_str());
  if (la < -90.0 || la > 90.0 || lo < -180.0 || lo > 180.0) return 0;
  String clean = asciiOnly(name, 10);
  receivePeerReport((uint8_t)id, clean.c_str(), la, lo);
  return 1;
}

int bridgeClearPeers() {
  {
    Lock l(&data_mtx);
    peerCount = 0;
    peersRev++;
  }
  postCmd(CMD_REDRAW, 0);
  return 1;
}

int bridgeSetProfile(String name, String title, String org) {
  {
    Lock l(&data_mtx);
    copyField(profName, sizeof(profName), name);
    copyField(profTitle, sizeof(profTitle), title);
    copyField(profOrg, sizeof(profOrg), org);
    profRev++;
  }
  postCmd(CMD_REDRAW, 0);
  return 1;
}

// QR upload: qr_begin(n) -> qr_data(byteOffset, hex) x N -> qr_end().
// Bits are row-major, LSB first (bit = row*n + col), 1 = dark module.
int bridgeQrBegin(int n) {
  if (n < 21 || n > QR_MAX_N) return 0;
  Lock l(&data_mtx);
  memset(qrBits, 0, sizeof(qrBits));
  qrN = n;
  qrReady = false;
  return 1;
}

int hexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

int bridgeQrData(int byteOffset, String hex) {
  Lock l(&data_mtx);
  if (qrN == 0 || byteOffset < 0) return 0;
  int totalBytes = (qrN * qrN + 7) / 8;
  for (unsigned int i = 0; i + 1 < hex.length(); i += 2) {
    int hi = hexNibble(hex[i]), lo = hexNibble(hex[i + 1]);
    if (hi < 0 || lo < 0) return 0;
    int pos = byteOffset + (int)(i / 2);
    if (pos >= totalBytes) return 0;
    qrBits[pos] = (uint8_t)((hi << 4) | lo);
  }
  return 1;
}

int bridgeQrEnd() {
  {
    Lock l(&data_mtx);
    if (qrN == 0) return 0;
    qrReady = true;
    profRev++;
  }
  postCmd(CMD_REDRAW, 0);
  return 1;
}

int bridgeQrClear() {
  {
    Lock l(&data_mtx);
    qrN = 0;
    qrReady = false;
    profRev++;
  }
  postCmd(CMD_REDRAW, 0);
  return 1;
}

// nav(action): 0 = short 6 (left), 1 = short 4 (right), 2 = hold 4 (select), 3 = hold 6 (back).
int bridgeNav(int action) {
  if (action < 0 || action > 3) return 0;
  return postCmd(CMD_NAV, action) ? 1 : 0;
}

// goto_screen(s): 0 = Home, 1..8 = the tiles.
int bridgeGotoScreen(int s) {
  if (s < 0 || s > NUM_APPS) return 0;
  return postCmd(CMD_GOTO, s) ? 1 : 0;
}

// find_badge(seconds): flash + buzz until it times out or a button is pressed.
int bridgeFind(int seconds) {
  if (seconds < 1) seconds = 1;
  if (seconds > 120) seconds = 120;
  return postCmd(CMD_FIND, seconds) ? 1 : 0;
}

int bridgeFindStop() {
  return postCmd(CMD_FIND, 0) ? 1 : 0;
}

// Bridge provider: Bridge.call("trigger_alert") from the app's SOS button.
// Queued, because the alarm pattern blocks for over a second and the bridge
// thread shouldn't sit in delay() (or Serial.println) on its tiny stack.
void bridgeTriggerAlert() {
  postCmd(CMD_ALERT, 0);
}

// voice_replay(): same as holding 4 on the Voice screen, from the app.
int bridgeVoiceReplay() {
  return postCmd(CMD_VOICE, 0) ? 1 : 0;
}

// set_clock("<local epoch seconds>") - sent as a string, it's too big for a small int.
int bridgeSetClock(String localEpoch) {
  long t = localEpoch.toInt();
  if (t < 1000000000L) return 0;
  Lock l(&data_mtx);
  clockBase = t - (long)(millis() / 1000UL);
  clockSet = true;
  return 1;
}

int bridgeSetBattery(int pct) {
  if (pct > 100) pct = 100;
  if (pct < -1) pct = -1;
  batteryPct = pct;
  cachesDirty = true;
  return 1;
}

int bridgeMarkRestored() {
  hubRestored = true;
  cachesDirty = true;                         // the hub's very next get_state must say "rs":1
  return 1;
}

// get_state() / get_gps() -> compact JSON. The hub polls both about once a
// second, and polling get_state is also what keeps the status-bar link dot
// green. loop() builds the strings a few times a second (buildCaches) and the
// bridge thread just hands back the last copy: concatenating a couple of
// hundred bytes on a 500-byte stack is a gamble nobody needs to take. Both
// stay well under the 256-byte message cap.
String buildStateJson() {
  int un = unreadCount();
  int np, nm;
  uint16_t mr, pr;
  {
    Lock l(&data_mtx);
    np = peerCount; nm = inboxCount; mr = inboxRev; pr = profRev;
  }
  int fx = currentPos().src;
  String s = "{\"v\":" + String(FW_PROTOCOL);
  s += ",\"id\":" + String(BADGE_ID);
  s += ",\"up\":" + String((unsigned long)(millis() / 1000UL));
  s += ",\"rs\":" + String(hubRestored ? 1 : 0);
  s += ",\"scr\":" + String((int)currentScreen);
  s += ",\"sel\":" + String(selectedTile);
  s += ",\"bl\":" + String(backlightPwm);
  s += ",\"hp\":" + String(hapticEnabled ? 1 : 0);
  s += ",\"pm\":" + String(peerAlertM);
  s += ",\"bat\":" + String(batteryPct);
  s += ",\"nt\":" + String(badgeTaskCount);
  s += ",\"tr\":" + String(tasksRev);
  s += ",\"nm\":" + String(nm);
  s += ",\"mr\":" + String(mr);
  s += ",\"un\":" + String(un);
  s += ",\"np\":" + String(np);
  s += ",\"ac\":" + String(alertCount);
  s += ",\"al\":" + String(alertCooldownLeft());
  s += ",\"vr\":" + String(voiceReplays);
  s += ",\"fd\":" + String(findUntil ? 1 : 0);
  s += ",\"pf\":" + String(pr);
  s += ",\"fx\":" + String(fx);
  s += "}";
  return s;
}

// The position the badge is actually using, the raw GPS details, and the
// distance/bearing to the destination.
String buildGpsJson() {
  Pos p = currentPos();
  Dest d = getDest();
  GpsSnap g;
  {
    Lock l(&data_mtx);
    g = gpsSnap;
  }
  unsigned long age = g.valid ? millis() - g.at : 0;
  String s = "{\"fx\":" + String(p.src);
  if (p.fix) {
    s += ",\"lat\":" + String(p.lat, 6);
    s += ",\"lon\":" + String(p.lon, 6);
    s += ",\"dst\":" + String(distanceMeters(p.lat, p.lon, d.lat, d.lon), 1);
    s += ",\"brg\":" + String(bearingDegrees(p.lat, p.lon, d.lat, d.lon), 1);
  }
  s += ",\"sat\":" + String(g.sats);
  s += ",\"hd\":" + String(g.hdop, 1);
  s += ",\"spd\":" + String(g.kmph, 1);
  s += ",\"crs\":" + String(g.course, 0);
  s += ",\"age\":" + String(g.valid ? (long)age : -1L);
  s += "}";
  return s;
}

void buildCaches() {
  cachesDirty = false;                        // cleared first: a change that lands mid-build re-dirties it
  String st = buildStateJson();
  String gp = buildGpsJson();
  Lock l(&data_mtx);
  stateCache = st;
  gpsCache = gp;
}

// A reply that was built before the change the caller just made would make the
// hub read a stale task count, so when a change is still waiting for loop() to
// fold it into the cache, hold the reply (up to half a second - loop() can be
// busy drawing a banner or buzzing) instead of answering with old data.
void waitForFreshCaches() {
  for (int i = 0; i < 100 && cachesDirty; i++) k_msleep(5);
}

String bridgeGetState() {
  hubSeenAt = millis();
  waitForFreshCaches();
  Lock l(&data_mtx);
  return stateCache;
}

String bridgeGetGps() {
  waitForFreshCaches();
  Lock l(&data_mtx);
  return gpsCache;
}

// get_diag() -> the slowest loop() passes (ms) since the last call, per section.
String bridgeGetDiag() {
  LoopStats p = loopPeak;
  loopPeak = { 0, 0, 0, 0, 0, 0, 0 };
  return "{\"tot\":" + String(p.total / 1000UL) + ",\"btn\":" + String(p.buttons / 1000UL) + ",\"ser\":" + String(p.serial / 1000UL)
       + ",\"cmd\":" + String(p.cmd / 1000UL) + ",\"cac\":" + String(p.caches / 1000UL) + ",\"tick\":" + String(p.tick / 1000UL)
       + ",\"flu\":" + String(p.flush / 1000UL) + "}";
}

// ---------------- Frame buffer -> panel ----------------
#define FLUSH_CHUNK_PIXELS 1024
static uint8_t flushChunk[FLUSH_CHUNK_PIXELS * 2];

// Send rows [y0, y0+rows) of the RAM frame (full width, so the rows are one
// contiguous run) to the panel: set the window, then stream RGB565 big-endian
// through the core's bulk SPI.transfer(buf, len).
void flushRows(int y0, int rows) {
  unsigned long t0 = micros();
  if (y0 < 0) y0 = 0;
  if (y0 + rows > SCREEN_H) rows = SCREEN_H - y0;
  if (rows <= 0) return;
  const uint16_t* src = frameBuf + (uint32_t)y0 * SCREEN_W;
  uint32_t left = (uint32_t)rows * SCREEN_W;
  panel.startWrite();                           // begins the SPI transaction, CS low
  panel.setAddrWindow(0, y0, SCREEN_W, rows);   // ends with the RAMWR command: data mode
  while (left) {
    uint32_t n = left < FLUSH_CHUNK_PIXELS ? left : FLUSH_CHUNK_PIXELS;
    for (uint32_t i = 0; i < n; i++) {
      uint16_t c = src[i];
      flushChunk[2 * i] = c >> 8;
      flushChunk[2 * i + 1] = c & 0xFF;
    }
    SPI.transfer(flushChunk, n * 2);            // overwrites flushChunk with the reply - it's rebuilt every pass
    src += n;
    left -= n;
  }
  panel.endWrite();
  unsigned long d = micros() - t0;
  if (d > loopPeak.flush) loopPeak.flush = d;
}

void flushAll() { flushRows(0, SCREEN_H); }

// ---------------- Buttons + navigation ----------------
void updateButtonIndicator(int pin, bool pressed);
void drawHome();
void drawScreen(Screen s);
void drawStatusBar();

void redrawCurrent() {
  drawScreen(currentScreen);
}

void enterScreen(Screen s) {
  currentScreen = s;
  if (s == SCR_INBOX) { selectedInboxIdx = 0; markAllRead(); }
  if (s == SCR_TASKS) { taskTop = 0; clampTaskSelection(); }
  if (s == SCR_BADGE) badgeQrFull = false;
  drawScreen(s);
}

void goHome() {
  currentScreen = HOME;
  drawScreen(HOME);
}

void onNavigate(int dir) {
  if (currentScreen == HOME) {
    selectedTile += dir;
    if (selectedTile < 1) selectedTile = NUM_APPS;
    if (selectedTile > NUM_APPS) selectedTile = 1;
    drawScreen(HOME);
  } else if (currentScreen == SCR_TASKS && badgeTaskCount > 0) {
    selectedBadgeTaskIdx += dir;
    if (selectedBadgeTaskIdx < 0) selectedBadgeTaskIdx = badgeTaskCount - 1;
    if (selectedBadgeTaskIdx >= badgeTaskCount) selectedBadgeTaskIdx = 0;
    drawScreen(SCR_TASKS);
  } else if (currentScreen == SCR_INBOX && inboxCount > 0) {
    selectedInboxIdx += dir;
    if (selectedInboxIdx < 0) selectedInboxIdx = inboxCount - 1;
    if (selectedInboxIdx >= inboxCount) selectedInboxIdx = 0;
    drawScreen(SCR_INBOX);
  } else if (currentScreen == SCR_SETTINGS) {
    settingsSelectedRow += dir;
    if (settingsSelectedRow < 0) settingsSelectedRow = SETTINGS_ROWS - 1;
    if (settingsSelectedRow >= SETTINGS_ROWS) settingsSelectedRow = 0;
    drawScreen(SCR_SETTINGS);
  }
}

void onSelect() {
  if (currentScreen == HOME) {
    enterScreen((Screen)selectedTile);
  } else if (currentScreen == SCR_TASKS) {
    if (badgeTaskCount == 0) return;
    // not done -> done on the first long-press, done -> cleared on the next
    if (badgeTasks[selectedBadgeTaskIdx].done) {
      deleteBadgeTask(selectedBadgeTaskIdx);
    } else {
      toggleBadgeTask(selectedBadgeTaskIdx);
    }
    drawScreen(SCR_TASKS);
  } else if (currentScreen == SCR_INBOX) {
    deleteInbox(selectedInboxIdx);
    drawScreen(SCR_INBOX);
  } else if (currentScreen == SCR_SETTINGS) {
    if (settingsSelectedRow == 0) {
      bridgeSetBrightness((brightnessLevel + 1) % 3);
    } else if (settingsSelectedRow == 1) {
      bridgeSetHaptic(!hapticEnabled);
    } else if (settingsSelectedRow == 2) {
      int next = 0;
      for (int i = 0; i < 4; i++) if (PEER_RANGES_M[i] == peerAlertM) next = (i + 1) % 4;
      bridgeSetPeerRange(PEER_RANGES_M[next]);
    }
    drawScreen(SCR_SETTINGS);
  } else if (currentScreen == SCR_ALERT) {
    triggerAlertIfReady();
    drawScreen(SCR_ALERT);
  } else if (currentScreen == SCR_VOICE) {
    announceCurrentReminder();
  } else if (currentScreen == SCR_BADGE) {
    if (qrReady) { badgeQrFull = !badgeQrFull; drawScreen(SCR_BADGE); }
  }
}

void onBack() {
  if (currentScreen == HOME) return;
  goHome();
}

// ---------------- Find-my-badge + banner overlays ----------------
void drawFindMe();
void drawBanner();

void startFind(int seconds) {
  findUntil = millis() + (unsigned long)seconds * 1000UL;
  findNextFlip = 0;
  findLit = true;
  drawFindMe();
}

void stopFind() {
  if (!findUntil) return;
  findUntil = 0;
  applyBrightness();
  redrawCurrent();
}

void serviceFind() {
  if (!findUntil) return;
  unsigned long now = millis();
  if ((long)(now - findUntil) >= 0) { stopFind(); return; }
  if ((long)(now - findNextFlip) >= 0) {
    findLit = !findLit;
    analogWrite(TFT_BL, findLit ? 255 : 8);
    findNextFlip = now + 350;
    if (findLit) buzz(70);     // buzzes whatever the Haptic setting says - you asked for it
  }
}

void showBanner(const String& text, bool buzzToo) {
  bannerText = text;
  bannerUntil = millis() + 6000UL;
  drawBanner();
  if (buzzToo && hapticEnabled) {
    buzz(90);
    delay(70);
    buzz(90);
  }
}

// A press that only closes an overlay shouldn't also navigate.
bool dismissOverlay() {
  if (findUntil) { stopFind(); return true; }
  if (bannerUntil) { bannerUntil = 0; redrawCurrent(); return true; }
  return false;
}

void serviceBanner() {
  if (bannerUntil && (long)(millis() - bannerUntil) >= 0) {
    bannerUntil = 0;
    redrawCurrent();
  }
}

// ---------------- Commands posted by Bridge handlers ----------------
uint32_t screenSig();

void runCmd(const Cmd& c) {
  switch (c.type) {
    case CMD_NAV:
      if (!dismissOverlay()) {
        if (c.arg == 0) onNavigate(-1);
        else if (c.arg == 1) onNavigate(1);
        else if (c.arg == 2) onSelect();
        else if (c.arg == 3) onBack();
      }
      break;
    case CMD_GOTO:
      dismissOverlay();
      if (c.arg == 0) goHome();
      else { selectedTile = c.arg; enterScreen((Screen)c.arg); }
      break;
    case CMD_ALERT:
      triggerAlertIfReady();
      if (currentScreen == SCR_ALERT && !findUntil && !bannerUntil) drawScreen(SCR_ALERT);
      break;
    case CMD_FIND:
      if (c.arg > 0) startFind(c.arg); else stopFind();
      break;
    case CMD_VOICE:
      announceCurrentReminder();
      break;
    case CMD_BANNER: {
      String t;
      { Lock l(&data_mtx); t = bannerPending; }
      if (!findUntil) showBanner(t, c.arg == 1);
      break;
    }
    case CMD_REDRAW: {
      if (findUntil || bannerUntil) break;
      uint32_t sig = screenSig();
      if (sig != lastScreenSig) { lastScreenSig = sig; redrawCurrent(); }
      break;
    }
  }
}

// ---------------- Status bar upkeep ----------------
void drawClock();
void drawUnreadChip();
void drawLinkAndBattery();

void tickStatusBar() {
  if (findUntil || bannerUntil) return;
  static int lastMinute = -2, lastUnread = -1, lastBat = -2;
  static bool lastLink = false;
  int h = 0, m = 0;
  int minuteNow = clockHM(h, m) ? h * 60 + m : -1;
  int unreadNow = unreadCount();
  bool linkNow = hubLinked();
  bool barChanged = false;
  if (minuteNow != lastMinute) { lastMinute = minuteNow; drawClock(); barChanged = true; }
  if (unreadNow != lastUnread) { lastUnread = unreadNow; drawUnreadChip(); barChanged = true; }
  if (linkNow != lastLink || batteryPct != lastBat) {
    lastLink = linkNow;
    lastBat = batteryPct;
    drawLinkAndBattery();
    barChanged = true;
  }
  if (barChanged) flushRows(0, 24);      // only the status bar rows changed
}

// What the current screen shows, folded into one number (see hashMix).
uint32_t screenSig() {
  uint32_t h = 2166136261u;
  switch (currentScreen) {
    case SCR_MAP: {
      Pos p = currentPos();
      Dest d = getDest();
      h = hashMix(h, (uint32_t)p.src);
      if (p.fix) {
        h = hashMix(h, (uint32_t)distanceMeters(p.lat, p.lon, d.lat, d.lon));
        h = hashMix(h, (uint32_t)(bearingDegrees(p.lat, p.lon, d.lat, d.lon) / 2.0));
      } else {
        Lock l(&data_mtx);
        h = hashMix(h, (uint32_t)gpsSnap.sats);
      }
      for (const char* ch = d.name; *ch; ch++) h = hashMix(h, (uint8_t)*ch);   // destination renamed
      break;
    }
    case SCR_PEERS: {
      Pos p = currentPos();
      h = hashMix(h, (uint32_t)p.fix);
      Lock l(&data_mtx);
      h = hashMix(h, (uint32_t)peerCount);
      for (int i = 0; i < peerCount; i++) {
        h = hashMix(h, peers[i].id);
        if (p.fix) h = hashMix(h, (uint32_t)distanceMeters(p.lat, p.lon, peers[i].lat, peers[i].lon));
        h = hashMix(h, (millis() - peers[i].lastSeen > PEER_STALE_MS) ? 1u : 0u);
      }
      break;
    }
    case SCR_TASKS:    h = hashMix(h, tasksRev);   break;
    case SCR_INBOX:    h = hashMix(h, inboxRev);   break;
    case SCR_ALERT:    h = hashMix(h, alertCooldownLeft() ? 1u : 0u); h = hashMix(h, hubLinked() ? 1u : 0u); break;
    case SCR_BADGE:    h = hashMix(h, profRev);    break;
    case SCR_SETTINGS: h = hashMix(h, (uint32_t)backlightPwm); h = hashMix(h, hapticEnabled ? 1u : 0u); h = hashMix(h, (uint32_t)peerAlertM); break;
    default: break;
  }
  return h;
}

// ---------------- setup / loop ----------------
#define PROVIDE(name, fn) do { if (!Bridge.provide(name, fn)) Serial.println("bridge: could not provide " name); } while (0)

void drawSplash() {
  tft.fillScreen(COL_BG);
  tft.setTextColor(COL_ACCENT, COL_BG);
  tft.setTextSize(3);
  tft.setCursor(79, 56);
  tft.print("QT BADGEr");
  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(82, 92);
  tft.print("v4 - linking to the hub...");
  flushAll();
}

void setup(void) {
  pinMode(BTN_6, INPUT_PULLUP);
  pinMode(BTN_4, INPUT_PULLUP);
  pinMode(VIBRATION_PIN, OUTPUT);

  // Screen first: if the Bridge is slow to come up you still see the badge boot
  // instead of a black panel.
  panel.init(172, 320);   // native panel res — do NOT pass 320,172 here
  panel.setRotation(1);   // rotate into 320x172 landscape (the RAM frame is already landscape)
  pinMode(TFT_BL, OUTPUT);
  applyBrightness();
  drawSplash();

  Serial.begin(9600);   // Monitor: this is also what brings the Bridge up
  gpsSerial.begin(9600);

  Bridge.begin();
  PROVIDE("add_task", bridgeAddTask);
  PROVIDE("toggle_task", bridgeToggleTask);
  PROVIDE("delete_task", bridgeDeleteTask);
  PROVIDE("clear_done", bridgeClearDone);
  PROVIDE("get_task", bridgeGetTask);
  PROVIDE("get_msg", bridgeGetMsg);
  PROVIDE("show_message", bridgeShowMessage);
  PROVIDE("delete_msg", bridgeDeleteMsg);
  PROVIDE("clear_msgs", bridgeClearMsgs);
  PROVIDE("set_brightness", bridgeSetBrightness);
  PROVIDE("set_backlight", bridgeSetBacklight);
  PROVIDE("set_haptic", bridgeSetHaptic);
  PROVIDE("set_peer_range", bridgeSetPeerRange);
  PROVIDE("trigger_alert", bridgeTriggerAlert);
  PROVIDE("voice_replay", bridgeVoiceReplay);
  PROVIDE("set_destination", bridgeSetDestination);
  PROVIDE("set_position", bridgeSetPosition);
  PROVIDE("peer_report", bridgePeerReport);
  PROVIDE("clear_peers", bridgeClearPeers);
  PROVIDE("set_profile", bridgeSetProfile);
  PROVIDE("qr_begin", bridgeQrBegin);
  PROVIDE("qr_data", bridgeQrData);
  PROVIDE("qr_end", bridgeQrEnd);
  PROVIDE("qr_clear", bridgeQrClear);
  PROVIDE("nav", bridgeNav);
  PROVIDE("goto_screen", bridgeGotoScreen);
  PROVIDE("find_badge", bridgeFind);
  PROVIDE("find_stop", bridgeFindStop);
  PROVIDE("set_clock", bridgeSetClock);
  PROVIDE("set_battery", bridgeSetBattery);
  PROVIDE("mark_restored", bridgeMarkRestored);
  PROVIDE("get_state", bridgeGetState);
  PROVIDE("get_gps", bridgeGetGps);
  PROVIDE("get_diag", bridgeGetDiag);

  drawScreen(HOME);
  buildCaches();
}

void loop() {
  unsigned long loopT0 = micros();
  while (gpsSerial.available()) {
    if (gps.encode(gpsSerial.read())) updateGpsSnap();
  }
  TIME_IT(buttons, handleButtons());
  TIME_IT(serial, pollSerialCommands());

  Cmd c;
  if (popCmd(c)) {
    TIME_IT(cmd, runCmd(c));
    TIME_IT(caches, buildCaches());
  }
  serviceFind();
  serviceBanner();

  static unsigned long lastCache = 0;
  if (millis() - lastCache >= 250) {
    lastCache = millis();
    TIME_IT(caches, buildCaches());
  }

  static unsigned long lastTick = 0;
  if (millis() - lastTick >= 1000) {
    lastTick = millis();
    unsigned long tickT0 = micros();

    if (!findUntil && !bannerUntil) {
      // repaint only when something the screen shows has actually changed
      uint32_t sig = screenSig();
      if (sig != lastScreenSig) { lastScreenSig = sig; redrawCurrent(); }
    }
    tickStatusBar();

    // proximity buzz: a fresh peer inside the alert radius, at most every 5 s
    static unsigned long lastProxBuzz = 0;
    if (hapticEnabled && peerCount > 0 && millis() - lastProxBuzz > 5000) {
      Pos p = currentPos();
      if (p.fix) {
        bool isNear = false;
        {
          Lock l(&data_mtx);
          for (int i = 0; i < peerCount; i++) {
            if (millis() - peers[i].lastSeen > PEER_STALE_MS) continue;
            if (distanceMeters(p.lat, p.lon, peers[i].lat, peers[i].lon) < peerAlertM) { isNear = true; break; }
          }
        }
        if (isNear) { lastProxBuzz = millis(); buzz(120); }
      }
    }
    unsigned long tickD = micros() - tickT0;
    if (tickD > loopPeak.tick) loopPeak.tick = tickD;
  }

  unsigned long loopD = micros() - loopT0;
  if (loopD > loopPeak.total) loopPeak.total = loopD;
}

// ---------------- Buttons ----------------
void handleButtons() {
  bool btn6Raw = digitalRead(BTN_6);
  bool btn4Raw = digitalRead(BTN_4);

  // --- PIN 6: short = navigate left, long = back / cancel ---
  if (btn6Raw == LOW && btn6PrevRaw == HIGH) {
    btn6PressStart = millis();
    btn6LongFired = false;
    if (dismissOverlay()) btn6LongFired = true;   // this press only closed find-me / a banner
    else updateButtonIndicator(6, true);
  } else if (btn6Raw == LOW && !btn6LongFired && millis() - btn6PressStart > LONG_PRESS_MS) {
    btn6LongFired = true;
    onBack();
  } else if (btn6Raw == HIGH && btn6PrevRaw == LOW) {
    if (!btn6LongFired && millis() - btn6PressStart > DEBOUNCE_MS) onNavigate(-1);
    updateButtonIndicator(6, false);
  }
  btn6PrevRaw = btn6Raw;

  // --- PIN 4: short = navigate right, long = select ---
  if (btn4Raw == LOW && btn4PrevRaw == HIGH) {
    btn4PressStart = millis();
    btn4LongFired = false;
    if (dismissOverlay()) btn4LongFired = true;
    else updateButtonIndicator(4, true);
  } else if (btn4Raw == LOW && !btn4LongFired && millis() - btn4PressStart > LONG_PRESS_MS) {
    btn4LongFired = true;
    onSelect();
  } else if (btn4Raw == HIGH && btn4PrevRaw == LOW) {
    if (!btn4LongFired && millis() - btn4PressStart > DEBOUNCE_MS) onNavigate(1);
    updateButtonIndicator(4, false);
  }
  btn4PrevRaw = btn4Raw;
}

void drawScreen(Screen s) {
  // Take the signature *before* drawing: if the data moves while we paint, the
  // next tick sees a different signature and repaints, instead of the new value
  // being swallowed as "already shown".
  uint32_t sig = (s == currentScreen) ? screenSig() : lastScreenSig;
  switch (s) {
    case SCR_MAP:      drawMap();      break;
    case SCR_PEERS:    drawPeers();    break;
    case SCR_TASKS:    drawTasks();    break;
    case SCR_VOICE:    drawVoice();    break;
    case SCR_ALERT:    drawAlert();    break;
    case SCR_SETTINGS: drawSettingsScreen(); break;
    case SCR_BADGE:    drawBadge();    break;
    case SCR_INBOX:    drawInbox();    break;
    default:           drawHome();
  }
  flushAll();
  lastScreenSig = sig;
}

// ---------------- Home: icon grid ----------------
void drawHome() {
  tft.fillScreen(COL_BG);
  drawStatusBar();

  for (int i = 0; i < NUM_APPS; i++) {
    Tile &t = tiles[i];
    bool sel = (i + 1 == selectedTile);
    tft.fillRoundRect(t.x, t.y, t.w, t.h, 8, sel ? t.color : COL_DIM);
    drawTileIcon(i, t.x + t.w / 2, t.y + t.h / 2 - 6, sel ? COL_BG : COL_TEXT);

    tft.setTextSize(1);
    tft.setTextColor(sel ? COL_BG : COL_TEXT, sel ? t.color : COL_DIM);
    int16_t x1, y1; uint16_t tw, th;
    tft.getTextBounds(t.label, 0, 0, &x1, &y1, &tw, &th);
    tft.setCursor(t.x + (t.w - tw) / 2, t.y + t.h - 14);
    tft.print(t.label);
  }
}

void drawTileIcon(int index, int cx, int cy, uint16_t c) {
  switch (index) {
    case 0: // Map pin
      tft.fillCircle(cx, cy - 4, 6, c);
      tft.fillTriangle(cx - 6, cy, cx + 6, cy, cx, cy + 10, c);
      break;
    case 1: // Peers
      tft.fillCircle(cx - 5, cy, 5, c);
      tft.fillCircle(cx + 5, cy, 5, c);
      break;
    case 2: // Tasks
      tft.drawRoundRect(cx - 8, cy - 8, 16, 16, 3, c);
      tft.drawLine(cx - 4, cy, cx - 1, cy + 4, c);
      tft.drawLine(cx - 1, cy + 4, cx + 5, cy - 5, c);
      break;
    case 3: // Voice
      tft.fillRoundRect(cx - 4, cy - 9, 8, 14, 4, c);
      tft.drawLine(cx, cy + 6, cx, cy + 10, c);
      tft.drawLine(cx - 5, cy + 10, cx + 5, cy + 10, c);
      break;
    case 4: // Alert
      tft.drawTriangle(cx, cy - 9, cx - 9, cy + 7, cx + 9, cy + 7, c);
      tft.drawLine(cx, cy - 2, cx, cy + 1, c);
      tft.drawPixel(cx, cy + 4, c);
      break;
    case 5: // Settings
      tft.drawCircle(cx, cy, 7, c);
      tft.drawCircle(cx, cy, 2, c);
      break;
    case 6: // Badge: an ID card on a lanyard
      tft.drawRoundRect(cx - 9, cy - 7, 18, 16, 2, c);
      tft.fillRect(cx - 3, cy - 10, 6, 3, c);
      tft.drawCircle(cx - 4, cy - 2, 2, c);
      tft.drawFastHLine(cx - 6, cy + 3, 12, c);
      tft.drawFastHLine(cx - 6, cy + 6, 8, c);
      break;
    case 7: // Inbox: an envelope
      tft.drawRect(cx - 9, cy - 6, 18, 13, c);
      tft.drawLine(cx - 9, cy - 6, cx, cy + 2, c);
      tft.drawLine(cx + 9, cy - 6, cx, cy + 2, c);
      break;
  }
}

// ---------------- Shared chrome ----------------
void drawClock() {
  tft.fillRect(66, 3, 44, 14, COL_BG);
  int h, m;
  if (!clockHM(h, m)) return;
  tft.setTextSize(1);
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(70, 6);
  if (h < 10) tft.print('0');
  tft.print(h);
  tft.print(':');
  if (m < 10) tft.print('0');
  tft.print(m);
}

// envelope + count while there are unread Inbox messages
void drawUnreadChip() {
  tft.fillRect(194, 2, 44, 18, COL_BG);
  int n = unreadCount();
  if (n <= 0) return;
  tft.drawRect(196, 6, 14, 10, COL_SKY);
  tft.drawLine(196, 6, 203, 11, COL_SKY);
  tft.drawLine(210, 6, 203, 11, COL_SKY);
  tft.setTextSize(1);
  tft.setTextColor(COL_SKY, COL_BG);
  tft.setCursor(214, 7);
  tft.print(n);
}

void drawLinkAndBattery() {
  int bx = SCREEN_W - 40, by = 5;
  tft.fillRect(SCREEN_W - 56, 2, 56, 18, COL_BG);
  tft.drawRoundRect(bx, by, 28, 12, 2, COL_TEXT);
  tft.fillRect(bx + 29, by + 3, 2, 6, COL_TEXT);
  if (batteryPct >= 0) {
    int fillW = map(constrain(batteryPct, 0, 100), 0, 100, 0, 24);
    tft.fillRect(bx + 2, by + 2, fillW, 8, batteryPct < 20 ? COL_HEART : COL_GOOD);
  } else {
    tft.setTextSize(1);
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(bx + 11, by + 2);
    tft.print("?");
  }
  tft.fillCircle(SCREEN_W - 50, by + 6, 3, hubLinked() ? COL_GOOD : COL_DIM);
}

void drawStatusBar() {
  tft.drawFastHLine(0, 22, SCREEN_W, COL_DIM);
  tft.setTextSize(1);
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(6, 6);
  tft.print("Badge #");
  tft.print(BADGE_ID);
  drawClock();

  // live button-press indicators — 6 on the left, 4 on the right, matching
  // which way each one navigates
  drawIndicatorBadge(IND6_X, "6", digitalRead(BTN_6) == LOW);
  drawIndicatorBadge(IND4_X, "4", digitalRead(BTN_4) == LOW);

  drawUnreadChip();
  drawLinkAndBattery();
}

void drawIndicatorBadge(int x, const char *digit, bool pressed) {
  tft.fillRoundRect(x, IND_Y, IND_W, IND_H, 3, pressed ? COL_ACCENT : COL_DIM);
  tft.setTextSize(1);
  tft.setTextColor(pressed ? COL_BG : COL_TEXT, pressed ? COL_ACCENT : COL_DIM);
  tft.setCursor(x + 4, IND_Y + 4);
  tft.print(digit);
}

// called on every press/release edge so feedback is instant without
// redrawing the whole screen each loop tick
void updateButtonIndicator(int pin, bool pressed) {
  if (pin == 6) drawIndicatorBadge(IND6_X, "6", pressed);
  if (pin == 4) drawIndicatorBadge(IND4_X, "4", pressed);
  flushRows(0, 24);
}

void drawBackHint() {
  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(6, SCREEN_H - 12);
  tft.print("hold 6 = back");
}

// Word-wrap s into at most maxLines lines of maxChars (default 6x8 font).
// The last line ends in ".." if the text didn't fit.
void printWrapped(const String& s, int x, int y, int maxChars, int maxLines, int lineH) {
  int pos = 0;
  int len = s.length();
  for (int line = 0; line < maxLines && pos < len; line++) {
    int end = pos + maxChars;
    if (end >= len) {
      end = len;
    } else {
      int sp = s.lastIndexOf(' ', end);
      if (sp > pos) end = sp;
    }
    String part = s.substring(pos, end);
    part.trim();
    if (line == maxLines - 1 && end < len && (int)part.length() > 2) {
      part = part.substring(0, part.length() - 2) + "..";
    }
    tft.setCursor(x, y + line * lineH);
    tft.print(part);
    pos = end;
    while (pos < len && s[pos] == ' ') pos++;
  }
}

// ---------------- App screens ----------------
void drawMap() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  Dest d = getDest();
  tft.setTextColor(COL_ACCENT, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print(d.name);

  Pos p = currentPos();
  if (!p.fix) {
    int sats;
    { Lock l(&data_mtx); sats = gpsSnap.sats; }
    tft.setTextSize(1);
    tft.setTextColor(COL_HEART, COL_BG);
    tft.setCursor(8, 55);
    tft.print("SEARCHING for GPS fix...");
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 70);
    tft.print("satellites: ");
    tft.print(sats);
    tft.setCursor(8, 84);
    tft.print("or send your phone's location");
    tft.setCursor(8, 96);
    tft.print("from the app (Map > Use phone GPS)");
    drawBackHint();
    return;
  }

  float dist = distanceMeters(p.lat, p.lon, d.lat, d.lon);
  float brg  = bearingDegrees(p.lat, p.lon, d.lat, d.lon);

  // GPS course only means anything while moving - the exact limitation
  // Pathfinder's writeup describes before they added a magnetometer.
  // There's no compass on this BOM yet, so standing still falls back to
  // an absolute bearing-from-North arrow instead of a true "turn this way."
  bool moving = false;
  float course = 0;
  if (p.src == 1) {
    Lock l(&data_mtx);
    moving = gpsSnap.spdValid && gpsSnap.kmph > 1.0 && gpsSnap.crsValid;
    course = gpsSnap.course;
  }
  float arrowAngle = moving ? fmod(brg - course + 360.0, 360.0) : brg;
  const char* headingSrc = moving ? "hdg: travel dir" : "hdg: from North";

  int cx = 240, cy = 95, r = 42;
  tft.drawCircle(cx, cy, r, COL_DIM);
  drawNavArrow(cx, cy, r - 10, arrowAngle, COL_ACCENT);

  tft.setTextSize(2);
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(8, 55);
  tft.print(dist < 1000 ? String((int)dist) + "m" : String(dist / 1000.0, 2) + "km");

  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, 78);
  tft.print("bearing ");
  tft.print((int)brg);
  tft.print(" deg");
  tft.setCursor(8, 92);
  tft.print(headingSrc);
  tft.setCursor(8, 106);
  tft.print(p.src == 1 ? "pos: badge GPS" : "pos: phone GPS");

  drawBackHint();
}

void drawPeers() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(COL_GOOD, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print("Peers");

  PeerInfo snap[MAX_PEERS];
  int n;
  { Lock l(&data_mtx); n = peerCount; for (int i = 0; i < n; i++) snap[i] = peers[i]; }
  Pos p = currentPos();

  tft.setTextSize(1);
  if (n == 0) {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("No peers yet - other badges and");
    tft.setCursor(8, 74);
    tft.print("phones report in through the hub");
  } else if (!p.fix) {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("Waiting for your own position");
  } else {
    int y = 50;
    for (int i = 0; i < n && i < MAX_PEERS; i++) {
      float d = distanceMeters(p.lat, p.lon, snap[i].lat, snap[i].lon);
      unsigned long age = (millis() - snap[i].lastSeen) / 1000UL;
      bool stale = (millis() - snap[i].lastSeen) > PEER_STALE_MS;
      tft.setTextColor(stale ? COL_DIM : (d < peerAlertM ? COL_HEART : COL_TEXT), COL_BG);
      tft.setCursor(12, y);
      if (snap[i].name[0]) tft.print(snap[i].name);
      else { tft.print("Badge "); tft.print(snap[i].id); }
      tft.print(" - ");
      if (d < 1000) { tft.print((int)d); tft.print(" m"); }
      else { tft.print(d / 1000.0, 1); tft.print(" km"); }
      if (age > 9) { tft.print("  ("); tft.print(age > 999 ? 999 : (int)age); tft.print("s)"); }
      y += 18;
    }
  }
  drawBackHint();
}

void drawTasks() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(COL_AMBER, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 30);
  tft.print("Tasks");

  tft.setTextSize(1);
  if (badgeTaskCount == 0) {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("No reminders from the hub yet");
  } else {
    int y = 50;
    const int rowH = 18;
    k_mutex_lock(&tasks_mtx, K_FOREVER);
    // keep the highlighted row on screen, so tasks 7-8 can be reached too
    if (selectedBadgeTaskIdx < taskTop) taskTop = selectedBadgeTaskIdx;
    if (selectedBadgeTaskIdx >= taskTop + TASK_ROWS) taskTop = selectedBadgeTaskIdx - TASK_ROWS + 1;
    if (taskTop > badgeTaskCount - TASK_ROWS) taskTop = badgeTaskCount - TASK_ROWS;
    if (taskTop < 0) taskTop = 0;
    int open = 0;
    for (int i = 0; i < badgeTaskCount; i++) if (!badgeTasks[i].done) open++;
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(80, 36);
    tft.print(open);
    tft.print(" open of ");
    tft.print(badgeTaskCount);
    for (int r = 0; r < TASK_ROWS && taskTop + r < badgeTaskCount; r++) {
      int i = taskTop + r;
      bool sel = (i == selectedBadgeTaskIdx);
      bool done = badgeTasks[i].done;
      if (sel) tft.drawRoundRect(6, y - 2, 304, rowH - 2, 4, COL_AMBER);
      tft.drawRect(12, y, 10, 10, COL_DIM);
      if (done) tft.fillRect(14, y + 2, 6, 6, COL_AMBER);
      String t = badgeTasks[i].text;
      if (t.length() > 34) t = t.substring(0, 32) + "..";
      tft.setTextColor(done ? COL_DIM : COL_TEXT, COL_BG);
      tft.setCursor(28, y);
      tft.print(t);
      y += rowH;
    }
    k_mutex_unlock(&tasks_mtx);
  }

  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, SCREEN_H - 24);
  tft.print("6/4 browse  hold 4: check off, then clear");
  drawBackHint();
}

void drawVoice() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(COL_PURPLE, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print("Voice");

  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, 55);
  tft.print("would speak:");

  String toSay = "no reminder right now";
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  for (int i = 0; i < badgeTaskCount; i++) {
    if (!badgeTasks[i].done) { toSay = badgeTasks[i].text; break; }
  }
  k_mutex_unlock(&tasks_mtx);
  if (toSay.length() > 34) toSay = toSay.substring(0, 32) + "..";
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(8, 70);
  tft.print(toSay);

  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, 92);
  tft.print("hold 4: replay - buzzes here,");
  tft.setCursor(8, 106);
  tft.print(hubLinked() ? "and the phone app reads it out" : "no hub link: buzz only");

  drawBackHint();
}

void drawAlert() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  bool onCooldown = alertCooldownLeft() > 0;

  tft.setTextColor(COL_CORAL, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print("Alert");

  tft.setTextSize(1);
  if (onCooldown) {
    tft.fillRoundRect(6, 52, 220, 24, 4, COL_HEART);
    tft.setTextColor(COL_TEXT, COL_HEART);
    tft.setCursor(14, 58);
    tft.print(hubLinked() ? "ALERT SENT - phone app notified" : "ALERT SENT - local alarm only");
  } else {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("hold 4 to send an alert");
    tft.setCursor(8, 74);
    tft.print(hubLinked() ? "hub link ok: the app gets it" : "no hub link: local alarm only");
  }

  drawBackHint();
}

void drawSettingsScreen() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print("Settings");

  tft.setTextSize(1);
  const char* rowLabels[SETTINGS_ROWS] = {"Brightness", "Haptic alerts", "Peer alert"};
  String rowValues[SETTINGS_ROWS];
  rowValues[0] = String(backlightPwm * 100 / 255) + "%";
  rowValues[1] = hapticEnabled ? "On" : "Off";
  rowValues[2] = String(peerAlertM) + " m";

  int y = 55;
  for (int i = 0; i < SETTINGS_ROWS; i++) {
    bool sel = (i == settingsSelectedRow);
    if (sel) tft.drawRoundRect(6, y - 3, 200, 20, 4, COL_ACCENT);
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(12, y);
    tft.print(rowLabels[i]);
    tft.setTextColor(COL_ACCENT, COL_BG);
    tft.setCursor(140, y);
    tft.print(rowValues[i]);
    y += 26;
  }

  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, SCREEN_H - 24);
  tft.print("6/4 browse   hold 4: change value");
  drawBackHint();
}

// QR: dark modules on a white box with a 2-module quiet zone. Horizontal runs
// of dark modules are drawn as one rect each, so a full code is ~a hundred
// SPI fills instead of a thousand.
void drawQr(int x, int y, int mod) {
  int n = qrN, q = 2;
  int side = (n + 2 * q) * mod;
  tft.fillRect(x, y, side, side, ST77XX_WHITE);
  for (int r = 0; r < n; r++) {
    int c = 0;
    while (c < n) {
      int bit = r * n + c;
      if (qrBits[bit >> 3] & (1 << (bit & 7))) {
        int run = 1;
        while (c + run < n) {
          int b2 = r * n + c + run;
          if (!(qrBits[b2 >> 3] & (1 << (b2 & 7)))) break;
          run++;
        }
        tft.fillRect(x + (q + c) * mod, y + (q + r) * mod, run * mod, mod, ST77XX_BLACK);
        c += run;
      } else {
        c++;
      }
    }
  }
}

// draws s at the biggest size (3, 2, then 1) that fits maxPx wide, cut off if even size 1 doesn't
void drawFitted(const char* s, int x, int y, int maxPx, uint16_t color, int maxSize) {
  int len = strlen(s);
  int size = maxSize;
  while (size > 1 && len * 6 * size > maxPx) size--;
  int fit = maxPx / (6 * size);
  String t = String(s);
  if ((int)t.length() > fit) t = t.substring(0, fit > 2 ? fit - 2 : fit) + "..";
  tft.setTextSize(size);
  tft.setTextColor(color, COL_BG);
  tft.setCursor(x, y);
  tft.print(t);
}

void drawBadge() {
  tft.fillScreen(COL_BG);
  drawStatusBar();

  char name[25], title[33], org[33];
  bool hasQr;
  {
    Lock l(&data_mtx);
    strcpy(name, profName);
    strcpy(title, profTitle);
    strcpy(org, profOrg);
    hasQr = qrReady && qrN >= 21;
  }

  if (hasQr && badgeQrFull) {
    int mod = 160 / (qrN + 4);
    if (mod < 2) mod = 2;
    int side = (qrN + 4) * mod;
    drawQr((SCREEN_W - side) / 2, 24 + (SCREEN_H - 24 - side) / 2, mod);
    return;
  }

  int textW = 304;
  if (hasQr) {
    int mod = 136 / (qrN + 4);
    if (mod < 2) mod = 2;
    int side = (qrN + 4) * mod;
    drawQr(SCREEN_W - side - 8, 24 + (SCREEN_H - 24 - side) / 2, mod);
    textW = SCREEN_W - side - 24;
  }

  if (name[0] == 0) {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setTextSize(1);
    tft.setCursor(8, 60);
    tft.print("No name set yet.");
    tft.setCursor(8, 74);
    tft.print("Set it in the app: Badge tab.");
    drawFitted("Badge", 8, 100, textW, COL_GOLD, 3);
    tft.setTextSize(1);
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, SCREEN_H - 12);
    tft.print("hold 6 = back");
    return;
  }

  drawFitted(name, 8, 44, textW, COL_TEXT, 3);
  int y = 44 + 32;
  if (title[0]) { drawFitted(title, 8, y, textW, COL_GOLD, 2); y += 24; }
  if (org[0])   { drawFitted(org,   8, y, textW, COL_ACCENT, 1); }

  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, SCREEN_H - 12);
  tft.print(hasQr ? "hold 4 = big QR   hold 6 = back" : "hold 6 = back");
}

void drawInbox() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(COL_SKY, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print("Inbox");

  InboxMsg snap[MAX_INBOX];
  int n, sel;
  { Lock l(&data_mtx); n = inboxCount; sel = selectedInboxIdx; for (int i = 0; i < n; i++) snap[i] = inbox[i]; }

  tft.setTextSize(1);
  if (n == 0) {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("No messages - send one from the app");
    drawBackHint();
    return;
  }

  int y = 46;
  for (int i = 0; i < n; i++) {
    bool isSel = (i == sel);
    if (isSel) tft.drawRoundRect(4, y - 2, 312, 14, 3, COL_SKY);
    tft.fillCircle(11, y + 3, 2, snap[i].unread ? COL_SKY : COL_DIM);
    String t = snap[i].text;
    if (t.length() > 44) t = t.substring(0, 42) + "..";
    tft.setTextColor(isSel ? COL_TEXT : COL_DIM, COL_BG);
    tft.setCursor(20, y);
    tft.print(t);
    y += 15;
  }
  // the selected message in full (rows above are cut to one line each)
  tft.drawFastHLine(0, 124, SCREEN_W, COL_DIM);
  tft.setTextColor(COL_TEXT, COL_BG);
  printWrapped(snap[sel].text, 8, 129, 51, 2, 10);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, SCREEN_H - 24);
  tft.print("6/4 browse  hold 4: delete");
  drawBackHint();
}

// ---------------- Overlays ----------------
void drawBanner() {
  tft.fillRoundRect(4, 108, 312, 60, 6, COL_SKY);
  tft.setTextColor(COL_BG, COL_SKY);
  tft.setTextSize(1);
  tft.setCursor(12, 113);
  tft.print("NEW MESSAGE  (any button closes)");
  tft.setTextSize(1);
  printWrapped(bannerText, 12, 128, 50, 3, 12);
  flushRows(104, SCREEN_H - 104);        // the banner sits in the bottom rows
}

void drawFindMe() {
  tft.fillScreen(COL_BG);
  tft.setTextColor(COL_HEART, COL_BG);
  tft.setTextSize(4);
  tft.setCursor(76, 52);
  tft.print("FIND ME");
  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(88, 110);
  tft.print("press any button to stop");
  flushAll();
}
