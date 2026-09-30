// Arduino UNO Qt BADGEr — badge UI (STM32 real-time core)
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
// functional; the actual mesh transport for Peers is still on hold
// (ESP-NOW needs Espressif silicon this board doesn't have). Voice is a
// stub — no speaker on the BOM, no BLE/LLM choice made for it yet.
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>
#include <TinyGPSPlus.h>
#include <math.h>
#include <Arduino_RouterBridge.h>
#include <zephyr/kernel.h>

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

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

int   mockBattery   = 83;
bool  mockConnected = true;

#define SCREEN_W 320
#define SCREEN_H 172

#define COL_BG      ST77XX_BLACK
#define COL_TEXT    ST77XX_WHITE
#define COL_DIM     0x39C7
#define COL_ACCENT  0x07FF
#define COL_HEART   0xF800
#define COL_GOOD    0x07E0
#define COL_AMBER   0xFD20
#define COL_PURPLE  0x780F
#define COL_CORAL   0xFA45

// ---- Destination waypoint (Pathfinder-style nav) ----
// No web config wired up yet for setting this remotely (WebUI.h shows the
// pattern - a captive-portal form POSTing lat/lon into NVS - if you want
// that ported over later). Hardcoded for now.
#define DEST_NAME "Booth 12"
#define DEST_LAT  6.68870
#define DEST_LON  -1.62430

// On UNO Q, use hardware Serial1 for pins 0 and 1.
// Legacy SoftwareSerial is not compatible.
#define gpsSerial Serial1
TinyGPSPlus gps;

enum Screen { HOME, SCR_MAP, SCR_PEERS, SCR_TASKS, SCR_VOICE, SCR_ALERT, SCR_SETTINGS };
const int NUM_APPS = 6;

Screen currentScreen = HOME;
int selectedTile = 1; // 1..NUM_APPS, maps onto the Screen enum (SCR_MAP=1 .. SCR_SETTINGS=6)

struct Tile { int x, y, w, h; uint16_t color; const char *label; };
Tile tiles[NUM_APPS] = {
  { 10,  30, 96, 62, COL_ACCENT, "Map"      },
  {116,  30, 96, 62, COL_GOOD,   "Peers"    },
  {222,  30, 96, 62, COL_AMBER,  "Tasks"    },
  { 10, 100, 96, 62, COL_PURPLE, "Voice"    },
  {116, 100, 96, 62, COL_CORAL,  "Alert"    },
  {222, 100, 96, 62, COL_DIM,    "Settings" },
};

// ---- Tasks screen: reminders assigned by the UNO Q hub over the mesh ----
// Same shape as Deskbuddy's Task struct + add/toggle/delete, but there's no
// keyboard or touchscreen here, so "add" isn't a local action — the hub
// calls addBadgeTask() once a reminder arrives over ESP-NOW. Browse and
// clear are the two things the wearer can do with just two buttons.
#define MAX_BADGE_TASKS 8
struct BadgeTask { String text; bool done; };
BadgeTask badgeTasks[MAX_BADGE_TASKS];
int badgeTaskCount = 0;
int selectedBadgeTaskIdx = 0;

// Bridge providers run on a separate thread from loop() (confirmed by the
// LED-matrix-painter example), and bridgeAddTask() below writes into
// badgeTasks[] from that thread while loop()/buttons read and write the
// same array. Same reason that example wraps matrix state in a mutex.
K_MUTEX_DEFINE(tasks_mtx);

void addBadgeTask(const String& text) {
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (badgeTaskCount < MAX_BADGE_TASKS) {
    badgeTasks[badgeTaskCount].text = text;
    badgeTasks[badgeTaskCount].done = false;
    badgeTaskCount++;
  }
  k_mutex_unlock(&tasks_mtx);
}

void toggleBadgeTask(int idx) {
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (idx >= 0 && idx < badgeTaskCount) badgeTasks[idx].done = !badgeTasks[idx].done;
  k_mutex_unlock(&tasks_mtx);
}

void deleteBadgeTask(int idx) {
  k_mutex_lock(&tasks_mtx, K_FOREVER);
  if (idx >= 0 && idx < badgeTaskCount) {
    for (int i = idx; i < badgeTaskCount - 1; i++) badgeTasks[i] = badgeTasks[i + 1];
    badgeTaskCount--;
  }
  k_mutex_unlock(&tasks_mtx);
}

// ---- Bridge provider for the Linux-side LLM script ----
// Confirmed against the LED-matrix-painter example: Bridge.provide(name,
// fn) registers a sketch-side function, called from a separate thread
// than loop() - which is exactly why addBadgeTask() now takes a mutex.
// Parameter type was originally guessed as std::string (matching that
// example's std::vector/std::array-by-value pattern), but the actual
// build failed: MsgPack's Unpacker has no unpack() overload for
// std::string, only for arduino::msgpack::str_t - which is Arduino's own
// String. RPClite's deserializer only knows how to hand a provider a
// String for text, not a std::string.
void bridgeAddTask(String text) {
  addBadgeTask(text);
}

// ---- Task editor over USB serial ----
// A WiFi-hosted page (like Deskbuddy's) needs WiFi.h/WebServer.h, which
// are ESP32-core libraries and won't compile here for the same reason
// ESP-NOW doesn't - this is the STM32 side, not Espressif silicon. USB
// serial sidesteps that entirely: it's the same cable already used to
// flash the board, and the Web Serial API lets a plain HTML page talk to
// it directly. Protocol is line-based, one message per line:
//   -> LIST                requests the current list
//   -> ADD|<text>          appends a task
//   -> TOGGLE|<index>      flips done on that task
//   -> DEL|<index>         removes that task
//   <- TASK|<index>|<0/1>|<text>   one line per task
//   <- END                         marks the end of a list dump
// Every mutating command re-sends the full list, so the page just
// re-renders on every reply rather than tracking diffs.
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
    addBadgeTask(line.substring(4));
    sendTaskList();
  } else if (line.startsWith("TOGGLE|")) {
    toggleBadgeTask(line.substring(7).toInt());
    sendTaskList();
  } else if (line.startsWith("DEL|")) {
    deleteBadgeTask(line.substring(4).toInt());
    sendTaskList();
  }
}

void pollSerialCommands() {
  static String buf = "";
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

bool btn6PrevRaw = HIGH, btn4PrevRaw = HIGH;
unsigned long btn6PressStart = 0, btn4PressStart = 0;
bool btn6LongFired = false, btn4LongFired = false;

// ---- button press indicator badges, top status bar ----
#define IND6_X 150
#define IND4_X 170
#define IND_Y  4
#define IND_W  14
#define IND_H  14

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

// Stand-in for real TTS: no speaker on this BOM, and no BLE/LLM choice
// made yet, so this is the one channel that's genuinely wired up today.
void announceCurrentReminder() {
  buzz(100);
  delay(80);
  buzz(100);
}

// ---- Peers: nearby badges, once a mesh is actually feeding this ----
// This file can't run ESP-NOW (STM32 core, not Espressif silicon). Paths
// in, whenever you pick one up: port this sketch onto an ESP32-S3 badge
// for native ESP-NOW, bridge to the UNO Q's Linux side for Bluetooth
// Mesh, or bridge over one of the I2C buses to a small radio co-processor
// (on hold for now, per your note). Whichever it ends up being,
// receivePeerReport() is the same entry point - call it once real reports
// exist and this screen and the proximity buzz both start working with
// zero further changes.
#define MAX_PEERS 6
#define PEER_ALERT_M 3.0
struct PeerInfo { uint8_t id; double lat; double lon; unsigned long lastSeen; };
PeerInfo peers[MAX_PEERS];
int peerCount = 0;

void receivePeerReport(uint8_t id, double lat, double lon) {
  for (int i = 0; i < peerCount; i++) {
    if (peers[i].id == id) {
      peers[i].lat = lat;
      peers[i].lon = lon;
      peers[i].lastSeen = millis();
      return;
    }
  }
  if (peerCount < MAX_PEERS) {
    peers[peerCount++] = { id, lat, lon, millis() };
  }
}

// ---- Settings: local device options, cycled with the same two buttons ----
// Now also settable remotely (Controls page in the app), so the same
// separate-thread concern as tasks_mtx applies here too.
K_MUTEX_DEFINE(controls_mtx);
#define SETTINGS_ROWS 2
int settingsSelectedRow = 0;
int brightnessLevel = 2; // 0=Low 1=Med 2=High, indexes BRIGHTNESS_LEVELS
const int BRIGHTNESS_LEVELS[3] = {80, 170, 255};
bool hapticEnabled = true;

void applyBrightness() {
  analogWrite(TFT_BL, BRIGHTNESS_LEVELS[brightnessLevel]); // needs a PWM-capable pin
}

// Bridge provider: Bridge.call("set_brightness", level) from the app's
// Controls page. level is clamped to the same 0=Low..2=High range the
// on-device Settings screen uses.
void bridgeSetBrightness(int level) {
  k_mutex_lock(&controls_mtx, K_FOREVER);
  if (level < 0) level = 0;
  if (level > 2) level = 2;
  brightnessLevel = level;
  applyBrightness();
  k_mutex_unlock(&controls_mtx);
}

// Bridge provider: Bridge.call("set_haptic", enabled) from the app.
void bridgeSetHaptic(bool enabled) {
  k_mutex_lock(&controls_mtx, K_FOREVER);
  hapticEnabled = enabled;
  k_mutex_unlock(&controls_mtx);
}

// ---- Alert: manual panic trigger for now ----
// Long-press 4 sends it, and now so can the app's SOS button. Tying this
// to the IMU's fall-detection (like EchoWear's MQG-HRV/TS-HGV) instead of
// - or in addition to - a manual/remote press is a natural next step
// once you want it; say the word.
unsigned long alertSentAt = 0;
#define ALERT_COOLDOWN_MS 5000

void sendAlertNotification() {
  // The local half of this is real and works right now: a distinct
  // buzzer pattern, no network needed. Reaching anyone else still needs
  // the mesh/Linux bridge discussed above - not built yet, so that part
  // stays a logged placeholder rather than a fake network call.
  for (int i = 0; i < 5; i++) {
    digitalWrite(VIBRATION_PIN, HIGH);
    delay(150);
    digitalWrite(VIBRATION_PIN, LOW);
    delay(100);
  }
  Serial.println("ALERT triggered - local alarm fired, network notify still pending");
}

// Shared by the button (onSelect) and the Bridge provider below, so the
// cooldown check-and-set only lives in one place. The mutex only guards
// that check-and-set, not the ~1.25s buzzer sequence itself - never hold
// a lock through a long blocking call.
void triggerAlertIfReady() {
  k_mutex_lock(&controls_mtx, K_FOREVER);
  bool ready = (millis() - alertSentAt > ALERT_COOLDOWN_MS);
  if (ready) alertSentAt = millis();
  k_mutex_unlock(&controls_mtx);
  if (ready) sendAlertNotification();
}

// Bridge provider: Bridge.call("trigger_alert") from the app's SOS button.
void bridgeTriggerAlert() {
  triggerAlertIfReady();
}

void setup(void) {
  Serial.begin(9600);
  gpsSerial.begin(9600);

  pinMode(BTN_6, INPUT_PULLUP);
  pinMode(BTN_4, INPUT_PULLUP);
  pinMode(VIBRATION_PIN, OUTPUT);

  Bridge.begin();
  Bridge.provide("add_task", bridgeAddTask);
  Bridge.provide("set_brightness", bridgeSetBrightness);
  Bridge.provide("set_haptic", bridgeSetHaptic);
  Bridge.provide("trigger_alert", bridgeTriggerAlert);

  tft.init(172, 320);   // native panel res — do NOT pass 320,172 here
  tft.setRotation(1);   // rotate into 320x172 landscape
  pinMode(TFT_BL, OUTPUT);
  applyBrightness();

  // demo reminders until the hub is actually pushing them over the mesh
  addBadgeTask("Meet Alex near stage B");
  addBadgeTask("Check booth 12 demo");

  // demo peer so Peers' rendering and proximity buzz are testable now -
  // delete once receivePeerReport() is being called for real
  receivePeerReport(2, DEST_LAT + 0.00003, DEST_LON + 0.00003);

  drawHome();
}

void loop() {
  while (gpsSerial.available()) gps.encode(gpsSerial.read());
  handleButtons();
  pollSerialCommands();

  static unsigned long lastTick = 0;
  if (millis() - lastTick >= 1000) {
    lastTick = millis();
    if (currentScreen == SCR_MAP) drawMap(); // keep the fix/coords live while open
    else if (currentScreen == SCR_TASKS) drawTasks(); // ready for hub-pushed updates
    else if (currentScreen == SCR_PEERS) drawPeers();
    else if (currentScreen == SCR_ALERT) drawAlert(); // clears "ALERT SENT" after cooldown

    if (hapticEnabled && gps.location.isValid()) {
      for (int i = 0; i < peerCount; i++) {
        float d = distanceMeters(gps.location.lat(), gps.location.lng(), peers[i].lat, peers[i].lon);
        if (d < PEER_ALERT_M) { buzz(120); break; }
      }
    }
  }
}

// ---------------- Buttons ----------------
void handleButtons() {
  bool btn6Raw = digitalRead(BTN_6);
  bool btn4Raw = digitalRead(BTN_4);

  // --- PIN 6: short = navigate left, long = back / cancel ---
  if (btn6Raw == LOW && btn6PrevRaw == HIGH) {
    btn6PressStart = millis();
    btn6LongFired = false;
    updateButtonIndicator(6, true);
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
    updateButtonIndicator(4, true);
  } else if (btn4Raw == LOW && !btn4LongFired && millis() - btn4PressStart > LONG_PRESS_MS) {
    btn4LongFired = true;
    onSelect();
  } else if (btn4Raw == HIGH && btn4PrevRaw == LOW) {
    if (!btn4LongFired && millis() - btn4PressStart > DEBOUNCE_MS) onNavigate(1);
    updateButtonIndicator(4, false);
  }
  btn4PrevRaw = btn4Raw;
}

void onNavigate(int dir) {
  if (currentScreen == HOME) {
    selectedTile += dir;
    if (selectedTile < 1) selectedTile = NUM_APPS;
    if (selectedTile > NUM_APPS) selectedTile = 1;
    drawHome();
  } else if (currentScreen == SCR_TASKS && badgeTaskCount > 0) {
    selectedBadgeTaskIdx += dir;
    if (selectedBadgeTaskIdx < 0) selectedBadgeTaskIdx = badgeTaskCount - 1;
    if (selectedBadgeTaskIdx >= badgeTaskCount) selectedBadgeTaskIdx = 0;
    drawTasks();
  } else if (currentScreen == SCR_SETTINGS) {
    settingsSelectedRow += dir;
    if (settingsSelectedRow < 0) settingsSelectedRow = SETTINGS_ROWS - 1;
    if (settingsSelectedRow >= SETTINGS_ROWS) settingsSelectedRow = 0;
    drawSettingsScreen();
  }
}

void onSelect() {
  if (currentScreen == HOME) {
    currentScreen = (Screen)selectedTile;
    drawScreen(currentScreen);
  } else if (currentScreen == SCR_TASKS) {
    if (badgeTaskCount == 0) return;
    // not done -> done on the first long-press, done -> cleared on the next
    if (badgeTasks[selectedBadgeTaskIdx].done) {
      deleteBadgeTask(selectedBadgeTaskIdx);
      if (selectedBadgeTaskIdx >= badgeTaskCount) selectedBadgeTaskIdx = badgeTaskCount - 1;
      if (selectedBadgeTaskIdx < 0) selectedBadgeTaskIdx = 0;
    } else {
      toggleBadgeTask(selectedBadgeTaskIdx);
    }
    drawTasks();
  } else if (currentScreen == SCR_SETTINGS) {
    if (settingsSelectedRow == 0) {
      bridgeSetBrightness((brightnessLevel + 1) % 3);
    } else if (settingsSelectedRow == 1) {
      bridgeSetHaptic(!hapticEnabled);
    }
    drawSettingsScreen();
  } else if (currentScreen == SCR_ALERT) {
    triggerAlertIfReady();
    drawAlert();
  } else if (currentScreen == SCR_VOICE) {
    announceCurrentReminder();
  }
}

void onBack() {
  if (currentScreen == HOME) return;
  currentScreen = HOME;
  drawHome();
}

void drawScreen(Screen s) {
  switch (s) {
    case SCR_MAP:      drawMap();      break;
    case SCR_PEERS:    drawPeers();    break;
    case SCR_TASKS:    drawTasks();    break;
    case SCR_VOICE:    drawVoice();    break;
    case SCR_ALERT:    drawAlert();    break;
    case SCR_SETTINGS: drawSettingsScreen(); break;
    default:           drawHome();
  }
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
  }
}

// ---------------- Shared chrome ----------------
void drawStatusBar() {
  tft.drawFastHLine(0, 22, SCREEN_W, COL_DIM);
  tft.setTextSize(1);
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(6, 6);
  tft.print("Badge #");
  tft.print(BADGE_ID);

  // live button-press indicators — 6 on the left, 4 on the right, matching
  // which way each one navigates
  drawIndicatorBadge(IND6_X, "6", digitalRead(BTN_6) == LOW);
  drawIndicatorBadge(IND4_X, "4", digitalRead(BTN_4) == LOW);

  int bx = SCREEN_W - 40, by = 5;
  tft.drawRoundRect(bx, by, 28, 12, 2, COL_TEXT);
  tft.fillRect(bx + 29, by + 3, 2, 6, COL_TEXT);
  int fillW = map(mockBattery, 0, 100, 0, 24);
  tft.fillRect(bx + 2, by + 2, fillW, 8, mockBattery < 20 ? COL_HEART : COL_GOOD);
  tft.fillCircle(SCREEN_W - 50, by + 6, 3, mockConnected ? COL_GOOD : COL_DIM);
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
}

void drawBackHint() {
  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(6, SCREEN_H - 12);
  tft.print("hold 6 = back");
}

void drawStub(const char *title, uint16_t color, const char *line1, const char *line2) {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(color, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 30);
  tft.print(title);
  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, 60);
  tft.print(line1);
  tft.setCursor(8, 74);
  tft.print(line2);
  drawBackHint();
}

// ---------------- App screens ----------------
void drawMap() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(COL_ACCENT, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print(DEST_NAME);

  if (!gps.location.isValid()) {
    tft.setTextSize(1);
    tft.setTextColor(COL_HEART, COL_BG);
    tft.setCursor(8, 55);
    tft.print("SEARCHING for GPS fix...");
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 70);
    tft.print("satellites: ");
    tft.print(gps.satellites.isValid() ? gps.satellites.value() : 0);
    drawBackHint();
    return;
  }

  double lat = gps.location.lat();
  double lon = gps.location.lng();
  float dist = distanceMeters(lat, lon, DEST_LAT, DEST_LON);
  float brg  = bearingDegrees(lat, lon, DEST_LAT, DEST_LON);

  // GPS course only means anything while moving - the exact limitation
  // Pathfinder's writeup describes before they added a magnetometer.
  // There's no compass on this BOM yet, so standing still falls back to
  // an absolute bearing-from-North arrow instead of a true "turn this way."
  bool moving = gps.speed.isValid() && gps.speed.kmph() > 1.0 && gps.course.isValid();
  float arrowAngle = moving ? fmod(brg - gps.course.deg() + 360.0, 360.0) : brg;
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

  drawBackHint();
}

void drawPeers() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  tft.setTextColor(COL_GOOD, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print("Peers");

  tft.setTextSize(1);
  if (peerCount == 0) {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("No mesh link yet - see the");
    tft.setCursor(8, 74);
    tft.print("comment above receivePeerReport()");
  } else if (!gps.location.isValid()) {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("Waiting for your own GPS fix");
  } else {
    double lat = gps.location.lat(), lon = gps.location.lng();
    int y = 50;
    for (int i = 0; i < peerCount && i < 6; i++) {
      float d = distanceMeters(lat, lon, peers[i].lat, peers[i].lon);
      tft.setTextColor(d < PEER_ALERT_M ? COL_HEART : COL_TEXT, COL_BG);
      tft.setCursor(12, y);
      tft.print("Badge ");
      tft.print(peers[i].id);
      tft.print(" - ");
      tft.print((int)d);
      tft.print(" m");
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
    int visible = badgeTaskCount < 6 ? badgeTaskCount : 6;
    for (int i = 0; i < visible; i++) {
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
  for (int i = 0; i < badgeTaskCount; i++) {
    if (!badgeTasks[i].done) { toSay = badgeTasks[i].text; break; }
  }
  if (toSay.length() > 34) toSay = toSay.substring(0, 32) + "..";
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(8, 70);
  tft.print(toSay);

  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, 92);
  tft.print("hold 4: replay - buzzes for now,");
  tft.setCursor(8, 106);
  tft.print("no speaker/BLE/LLM wired up yet");

  drawBackHint();
}

void drawAlert() {
  tft.fillScreen(COL_BG);
  drawStatusBar();
  bool onCooldown = (millis() - alertSentAt) < ALERT_COOLDOWN_MS;

  tft.setTextColor(COL_CORAL, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 28);
  tft.print("Alert");

  tft.setTextSize(1);
  if (onCooldown) {
    tft.fillRoundRect(6, 52, 220, 24, 4, COL_HEART);
    tft.setTextColor(COL_TEXT, COL_HEART);
    tft.setCursor(14, 58);
    tft.print("ALERT SENT - local alarm fired");
  } else {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setCursor(8, 60);
    tft.print("hold 4 to send an alert");
    tft.setCursor(8, 74);
    tft.print("network notify: not wired yet");
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
  const char* rowLabels[SETTINGS_ROWS] = {"Brightness", "Haptic alerts"};
  String rowValues[SETTINGS_ROWS];
  rowValues[0] = brightnessLevel == 0 ? "Low" : (brightnessLevel == 1 ? "Med" : "High");
  rowValues[1] = hapticEnabled ? "On" : "Off";

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
