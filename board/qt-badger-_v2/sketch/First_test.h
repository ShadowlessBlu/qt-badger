#include <Adafruit_GFX.h>    // Core graphics library
#include <Adafruit_ST7789.h> // Hardware-specific library for ST7789
#include <SPI.h>

#define TFT_CS    10
#define TFT_RST   8
#define TFT_DC    7
#define TFT_BL 9   // uncomment + pinMode/digitalWrite HIGH if backlight is gated by a GPIO

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

// ---- Mock sensor values — replace with real reads from MAX3010x / INA219 / MPU6050 ----
int   mockHeartRate = 72;     // bpm
float mockHRV       = 48.3;   // ms
int   mockBattery   = 83;     // %
bool  mockConnected = true;   // ESP-NOW / BLE link state
int   waveform[64];           // fake PPG trace, for the little scope line

#define SCREEN_W 320   // after setRotation(1): 172x320 panel becomes 320x172 landscape
#define SCREEN_H 172

#define COL_BG      ST77XX_BLACK
#define COL_TEXT    ST77XX_WHITE
#define COL_DIM     0x39C7   // dark gray
#define COL_ACCENT  0x07FF   // cyan
#define COL_HEART   0xF800   // red
#define COL_GOOD    0x07E0   // green

void setup(void) {
  Serial.begin(9600);

  tft.init(172, 320);        // native panel res — do NOT pass 320,172 here
  tft.setRotation(1);        // rotate into 320x172 landscape for the UI below
  tft.fillScreen(COL_BG);
  pinMode(TFT_BL,OUTPUT);
  digitalWrite(TFT_BL, HIGH);
  for (int i = 0; i < 64; i++) {
    waveform[i] = 20 + (int)(15 * sin(i * 0.35)) + random(-3, 3);
  }

  drawStaticFrame();
  drawStatusBar();
  drawHeartRatePanel();
  drawHRVPanel();
  drawWaveform();
}

void loop() {
  // Mock UI is static for now. When you wire in real sensor data,
  // call the relevant draw*() function again on new readings rather
  // than re-drawing the whole screen every loop — full-screen redraws
  // on a 172x320 panel over SPI are visibly slow if done every frame.
}

// ---------- Layout pieces ----------

void drawStaticFrame() {
  tft.drawFastHLine(0, 22, SCREEN_W, COL_DIM);          // under status bar
  tft.drawFastVLine(190, 26, SCREEN_H - 26, COL_DIM);   // split: HR | HRV + wave
}

void drawStatusBar() {
  tft.setTextSize(1);
  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setCursor(6, 6);
  tft.print("09:41");

  // battery pill, top-right
  int bx = SCREEN_W - 40, by = 5;
  tft.drawRoundRect(bx, by, 28, 12, 2, COL_TEXT);
  tft.fillRect(bx + 29, by + 3, 2, 6, COL_TEXT);  // terminal nub
  int fillW = map(mockBattery, 0, 100, 0, 24);
  tft.fillRect(bx + 2, by + 2, fillW, 8, mockBattery < 20 ? ST77XX_RED : COL_GOOD);

  // link status dot
  tft.fillCircle(SCREEN_W - 50, by + 6, 3, mockConnected ? COL_GOOD : COL_DIM);
}

void drawHeartRatePanel() {
  drawHeart(30, 55, mockHeartRate > 0);

  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setTextSize(4);
  tft.setCursor(58, 40);
  tft.print(mockHeartRate);

  tft.setTextSize(1);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.setCursor(58, 78);
  tft.print("BPM");
}

void drawHeart(int x, int y, bool beat) {
  uint16_t c = beat ? COL_HEART : COL_DIM;
  tft.fillCircle(x - 6, y, 8, c);
  tft.fillCircle(x + 6, y, 8, c);
  tft.fillTriangle(x - 13, y + 4, x + 13, y + 4, x, y + 20, c);
}

void drawHRVPanel() {
  tft.setTextColor(COL_ACCENT, COL_BG);
  tft.setTextSize(1);
  tft.setCursor(200, 32);
  tft.print("HRV");

  tft.setTextColor(COL_TEXT, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(200, 44);
  tft.print(mockHRV, 1);
  tft.setTextSize(1);
  tft.print(" ms");
}

void drawWaveform() {
  int x0 = 200, y0 = 130, w = 110, h = 36;
  tft.drawRect(x0 - 2, y0 - h - 2, w + 4, h + 4, COL_DIM);
  for (int i = 1; i < 64; i++) {
    tft.drawLine(x0 + (i - 1) * (w / 64), y0 - waveform[i - 1],
                 x0 + i * (w / 64),       y0 - waveform[i],
                 COL_ACCENT);
  }
}
