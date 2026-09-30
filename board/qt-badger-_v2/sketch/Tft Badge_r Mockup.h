#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>
#include <TinyGPSPlus.h>

#define TFT_CS    10
#define TFT_RST   8
#define TFT_DC    7
#define TFT_BL    9

// Two-button nav: 6 moves the highlight right-to-left (left), 4 moves it
// left-to-right (right). Hold 6 to select, hold 4 to back out / cancel.
// Wired active-LOW with INPUT_PULLUP — button's other leg goes to GND.
#define BTN_4          4
#define BTN_6          6
#define LONG_PRESS_MS  600
#define DEBOUNCE_MS    30
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


bool btn4PrevRaw = HIGH, btn6PrevRaw = HIGH;
unsigned long btn4PressStart = 0, btn6PressStart = 0;
bool btn4LongFired = false, btn6LongFired = false;

void setup(void) {
  Serial.begin(9600);
  gpsSerial.begin(9600);

  pinMode(BTN_4, INPUT_PULLUP);
  pinMode(BTN_6, INPUT_PULLUP);

  tft.init(172, 320);   // native panel res — do NOT pass 320,172 here
  tft.setRotation(1);   // rotate into 320x172 landscape
  pinMode(TFT_BL, OUTPUT);
  digitalWrite(TFT_BL, HIGH);

  drawHome();
}

void loop() {
  while (gpsSerial.available()) gps.encode(gpsSerial.read());
  handleButtons();

  static unsigned long lastTick = 0;
  if (millis() - lastTick >= 1000) {
    lastTick = millis();
    if (currentScreen == SCR_MAP) drawMap(); // keep the fix/coords live while open
  }
}

// ---------------- Buttons ----------------
void handleButtons() {
  bool btn4Raw = digitalRead(BTN_4);
  bool btn6Raw = digitalRead(BTN_6);

  // --- PIN 4 LOGIC (Short = Navigate Right, Long = Select) ---
  if (btn4Raw == LOW && btn4PrevRaw == HIGH) {
    btn4PressStart = millis();
    btn4LongFired = false;
  } else if (btn4Raw == LOW && !btn4LongFired && millis() - btn4PressStart > LONG_PRESS_MS) {
    btn4LongFired = true;
    onSelect();
  } else if (btn4Raw == HIGH && btn4PrevRaw == LOW) {
    if (!btn4LongFired && millis() - btn4PressStart > DEBOUNCE_MS) {
      onNavigate(1); // 1 = Move Right
    }
  }
  btn4PrevRaw = btn4Raw;

  // --- PIN 6 LOGIC (Short = Navigate Left, Long = Back/Cancel) ---
  if (btn6Raw == LOW && btn6PrevRaw == HIGH) {
    btn6PressStart = millis();
    btn6LongFired = false;
  } else if (btn6Raw == LOW && !btn6LongFired && millis() - btn6PressStart > LONG_PRESS_MS) {
    btn6LongFired = true;
    onBack();
  } else if (btn6Raw == HIGH && btn6PrevRaw == LOW) {
    if (!btn6LongFired && millis() - btn6PressStart > DEBOUNCE_MS) {
      onNavigate(-1); // -1 = Move Left
    }
  }
  btn6PrevRaw = btn6Raw;
}

void onNavigate(int dir) {
  if (currentScreen != HOME) return; // only the home grid scrolls
  selectedTile += dir;
  if (selectedTile < 1) selectedTile = NUM_APPS;
  if (selectedTile > NUM_APPS) selectedTile = 1;
  drawHome();
}

void onSelect() {
  if (currentScreen != HOME) return;
  currentScreen = (Screen)selectedTile;
  drawScreen(currentScreen);
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

  int bx = SCREEN_W - 40, by = 5;
  tft.drawRoundRect(bx, by, 28, 12, 2, COL_TEXT);
  tft.fillRect(bx + 29, by + 3, 2, 6, COL_TEXT);
  int fillW = map(mockBattery, 0, 100, 0, 24);
  tft.fillRect(bx + 2, by + 2, fillW, 8, mockBattery < 20 ? COL_HEART : COL_GOOD);
  tft.fillCircle(SCREEN_W - 50, by + 6, 3, mockConnected ? COL_GOOD : COL_DIM);
}

void drawBackHint() {
  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(6, SCREEN_H - 12);
  tft.print("hold 4 = back");
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
void drawTasks()          { drawStub("Tasks",    COL_AMBER,  "reminders not wired up yet -", "stub screen for now"); }
void drawVoice()          { drawStub("Voice",    COL_PURPLE, "LLM feedback not wired up",    "yet - stub screen for now"); }
void drawAlert()          { drawStub("Alert",    COL_CORAL,  "panic / SOS not wired up",      "yet - stub screen for now"); }
void drawSettingsScreen() { drawStub("Settings", COL_TEXT,   "battery + link config -",       "stub screen for now"); }
