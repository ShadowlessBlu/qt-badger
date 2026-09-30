#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>
#include <TinyGPSPlus.h>

#define TFT_CS    10
#define TFT_RST   8
#define TFT_DC    7
#define TFT_BL    9

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

void addBadgeTask(const String& text) {
  if (badgeTaskCount >= MAX_BADGE_TASKS) return;
  badgeTasks[badgeTaskCount].text = text;
  badgeTasks[badgeTaskCount].done = false;
  badgeTaskCount++;
}

void toggleBadgeTask(int idx) {
  if (idx < 0 || idx >= badgeTaskCount) return;
  badgeTasks[idx].done = !badgeTasks[idx].done;
}

void deleteBadgeTask(int idx) {
  if (idx < 0 || idx >= badgeTaskCount) return;
  for (int i = idx; i < badgeTaskCount - 1; i++) badgeTasks[i] = badgeTasks[i + 1];
  badgeTaskCount--;
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

void setup(void) {
  Serial.begin(9600);
  gpsSerial.begin(9600);

  pinMode(BTN_6, INPUT_PULLUP);
  pinMode(BTN_4, INPUT_PULLUP);

  tft.init(172, 320);   // native panel res — do NOT pass 320,172 here
  tft.setRotation(1);   // rotate into 320x172 landscape
  pinMode(TFT_BL, OUTPUT);
  digitalWrite(TFT_BL, HIGH);

  // demo reminders until the hub is actually pushing them over the mesh
  addBadgeTask("Meet Alex near stage B");
  addBadgeTask("Check booth 12 demo");

  drawHome();
}

void loop() {
  while (gpsSerial.available()) gps.encode(gpsSerial.read());
  handleButtons();

  static unsigned long lastTick = 0;
  if (millis() - lastTick >= 1000) {
    lastTick = millis();
    if (currentScreen == SCR_MAP) drawMap(); // keep the fix/coords live while open
    else if (currentScreen == SCR_TASKS) drawTasks(); // ready for hub-pushed updates
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
  tft.print("Badge #1");

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
  tft.setCursor(8, 30);
  tft.print("Map");

  tft.setTextSize(1);
  tft.setCursor(8, 55);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("STATUS:");
  tft.setTextColor(gps.location.isValid() ? COL_GOOD : COL_HEART, COL_BG);
  tft.print(gps.location.isValid() ? " FIXED" : " SEARCHING...");

  tft.setCursor(8, 72);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("SATELLITES:");
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.print(gps.satellites.isValid() ? gps.satellites.value() : 0);

  tft.setCursor(8, 90);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("LAT:");
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.print(gps.location.isValid() ? String(gps.location.lat(), 6) : "---");

  tft.setCursor(8, 106);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("LON:");
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.print(gps.location.isValid() ? String(gps.location.lng(), 6) : "---");

  drawBackHint();
}

void drawPeers()          { drawStub("Peers",    COL_GOOD,   "mesh data not wired up yet -", "stub screen for now"); }

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
  }

  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(8, SCREEN_H - 24);
  tft.print("6/4 browse  hold 4: check off, then clear");
  drawBackHint();
}

void drawVoice()          { drawStub("Voice",    COL_PURPLE, "LLM feedback not wired up",    "yet - stub screen for now"); }
void drawAlert()          { drawStub("Alert",    COL_CORAL,  "panic / SOS not wired up",      "yet - stub screen for now"); }
void drawSettingsScreen() { drawStub("Settings", COL_TEXT,   "battery + link config -",       "stub screen for now"); }
