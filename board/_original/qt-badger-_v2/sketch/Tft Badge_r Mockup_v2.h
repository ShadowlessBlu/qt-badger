// Arduino UNO Qt BADGEr — badge UI (STM32 real-time core)
// v3: Bridge wired for real — Arduino_RouterBridge confirmed against a
// working Arduino example (LED matrix + RouterBridge), including the
// separate-thread caveat that made the tasks_mtx mutex necessary.
// bridgeAddTask() is registered as "add_task" for llm_schedule_organizer.py
// to call via Bridge.call(). Map is a Pathfinder-style waypoint navigator
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

#define TFT_CS     10
#define TFT_RST    8
#define TFT_DC     7
#define TFT_BL     9
#define VIBRATION_PIN 5   // proximity buzz for Peers - adjust to your wiring
#define BADGE_ID 1        // change per physical unit

// Two-button nav, named after the pin number (not left/right) to avoid
// exactly the kind of mismatch that caused the last bug:
//    Pin 6 - short press: move highlight left.    long press: back / cancel.
//    Pin 4 - short press: move highlight right.   long press: select.
// Wired active-LOW with INPUT_PULLUP — button's other leg goes to GND.
#define BTN_6         6
#define BTN_4         4
#define LONG_PRESS_MS  600
#define DEBOUNCE_MS    30

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

int    mockBattery   = 83;
bool   mockConnected = true;

#define SCREEN_W 320
#define SCREEN_H 172

#define COL_BG     ST77XX_BLACK
#define COL_TEXT   ST77XX_WHITE
#define COL_DIM    0x39C7
#define COL_ACCENT 0x07FF
#define COL_HEART  0xF800
#define COL_GOOD   0x07E0
#define COL_AMBER  0xFD20
#define COL_PURPLE 0x780F
#define COL_CORAL  0xFA45

// ---- Destination waypoint (Pathfinder-style nav) ----
#define DEST_NAME "Booth 12"
#define DEST_LAT  6.68870
#define DEST_LON  -1.62430

// On UNO Q, use hardware Serial1 for pins 0 and 1.
#define gpsSerial Serial1
TinyGPSPlus gps;

enum Screen { HOME, SCR_MAP, SCR_PEERS, SCR_TASKS, SCR_VOICE, SCR_ALERT, SCR_SETTINGS };
const int NUM_APPS = 6;

Screen currentScreen = HOME;
int selectedTile = 1;

struct Tile { int x, y, w, h; uint16_t color; const char *label; };
Tile tiles[NUM_APPS] = {
  { 10,   30, 96, 62, COL_ACCENT, "Map"      },
  {116,   30, 96, 62, COL_GOOD,   "Peers"    },
  {222,   30, 96, 62, COL_AMBER,  "Tasks"    },
  { 10,  100, 96, 62, COL_PURPLE, "Voice"    },
  {116,  100, 96, 62, COL_CORAL,  "Alert"    },
  {222,  100, 96, 62, COL_DIM,    "Settings" },
};

#define MAX_BADGE_TASKS 8
struct BadgeTask { String text; bool done; };
BadgeTask badgeTasks[MAX_BADGE_TASKS];
int badgeTaskCount = 0;
int selectedBadgeTaskIdx = 0;

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
// Updated parameter type to Arduino's String to match MsgPack's str_t unpacker.
void bridgeAddTask(String text) {
  addBadgeTask(text);
}

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

#define IND6_X 150
#define IND4_X 170
#define IND_Y  4
#define IND_W  14
#define IND_H  14

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

void announceCurrentReminder() {
  buzz(100);
  delay(80);
  buzz(100);
}

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

#define SETTINGS_ROWS 2
int settingsSelectedRow = 0;
int brightnessLevel = 2;
const int BRIGHTNESS_LEVELS[3] = {80, 170, 255};
bool hapticEnabled = true;

void applyBrightness() {
  analogWrite(TFT_BL, BRIGHTNESS_LEVELS[brightnessLevel]);
}

unsigned long alertSentAt = 0;
#define ALERT_COOLDOWN_MS 5000

void sendAlertNotification() {
  for (int i = 0; i < 5; i++) {
    digitalWrite(VIBRATION_PIN, HIGH);
    delay(150);
    digitalWrite(VIBRATION_PIN, LOW);
    delay(100);
  }
  Serial.println("ALERT triggered - local alarm fired, network notify still pending");
}

void setup(void) {
  Serial.begin(9600);
  gpsSerial.begin(9600);

  pinMode(BTN_6, INPUT_PULLUP);
  pinMode(BTN_4, INPUT_PULLUP);
  pinMode(VIBRATION_PIN, OUTPUT);

  Bridge.begin();
  Bridge.provide("add_task", bridgeAddTask);

  tft.init(172, 320);
  tft.setRotation(1);
  pinMode(TFT_BL, OUTPUT);
  applyBrightness();

  addBadgeTask("Meet Alex near stage B");
  addBadgeTask("Check booth 12 demo");
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
    if (currentScreen == SCR_MAP) drawMap();
    else if (currentScreen == SCR_TASKS) drawTasks();
    else if (currentScreen == SCR_PEERS) drawPeers();
    else if (currentScreen == SCR_ALERT) drawAlert();

    if (hapticEnabled && gps.location.isValid()) {
      for (int i = 0; i < peerCount; i++) {
        float d = distanceMeters(gps.location.lat(), gps.location.lng(), peers[i].lat, peers[i].lon);
        if (d < PEER_ALERT_M) { buzz(120); break; }
      }
    }
  }
}

void handleButtons() {
  bool btn6Raw = digitalRead(BTN_6);
  bool btn4Raw = digitalRead(BTN_4);

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
      brightnessLevel = (brightnessLevel + 1) % 3;
      applyBrightness();
    } else if (settingsSelectedRow == 1) {
      hapticEnabled = !hapticEnabled;
    }
    drawSettingsScreen();
  } else if (currentScreen == SCR_ALERT) {
    if (millis() - alertSentAt > ALERT_COOLDOWN_MS) {
      alertSentAt = millis();
      sendAlertNotification();
    }
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
    case 0:
      tft.fillCircle(cx, cy - 4, 6, c);
      tft.fillTriangle(cx - 6, cy, cx + 6, cy, cx, cy + 10, c);
      break;
    case 1:
      tft.fillCircle(cx - 5, cy, 5, c);
      tft.fillCircle(cx + 5, cy, 5, c);
      break;
    case 2:
      tft.drawRoundRect(cx - 8, cy - 8, 16, 16, 3, c);
      tft.drawLine(cx - 4, cy, cx - 1, cy + 4, c);
      tft.drawLine(cx - 1, cy + 4, cx + 5, cy - 5, c);
      break;
    case 3:
      tft.fillRoundRect(cx - 4, cy - 9, 8, 14, 4, c);
      tft.drawLine(cx, cy + 6, cx, cy + 10, c);
      tft.drawLine(cx - 5, cy + 10, cx + 5, cy + 10, c);
      break;
    case 4:
      tft.drawTriangle(cx, cy - 9, cx - 9, cy + 7, cx + 9, cy + 7, c);
      tft.drawLine(cx, cy - 2, cx, cy + 1, c);
      tft.drawPixel(cx, cy + 4, c);
      break;
    case 5:
      tft.drawCircle(cx, cy, 7, c);
      tft.drawCircle(cx, cy, 2, c);
      break;
  }
}

void drawStatusBar() {
  tft.drawFastHLine(0, 22, SCREEN_W, COL_DIM);
  tft.setTextSize(1);
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(6, 6);
  tft.print("Badge #");
  tft.print(BADGE_ID);

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