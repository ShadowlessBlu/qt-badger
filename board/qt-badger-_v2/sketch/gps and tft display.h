#include <Adafruit_GFX.h>    // Core graphics library
#include <Adafruit_ST7789.h> // Hardware-specific library for ST7789
#include <SPI.h>
#include <TinyGPSPlus.h>   // Library Manager: "TinyGPSPlus" by Mikal Hart

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


// On UNO Q, use hardware Serial1 for pins 0 and 1.
// Legacy SoftwareSerial is not compatible.
#define gpsSerial Serial1 

TinyGPSPlus gps;
unsigned long lastPrint = 0;

void setup(void) {
  Serial.begin(9600);

  // Initialize communication with the ATGM336H GPS module
  gpsSerial.begin(9600);   
  
  Serial.println(F("--- UNO Q Extended ATGM336H GPS Test ---"));
  Serial.println(F("Ensure you have a clear sky view for a valid fix."));
  Serial.println();

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

  // Keep feeding NMEA data to TinyGPSPlus continuously
  while (gpsSerial.available()) {
    gps.encode(gpsSerial.read());
  }

  // Update display and Serial output once every second
  static unsigned long lastGPSDisplay = 0;

  if (millis() - lastGPSDisplay >= 1000) {
    lastGPSDisplay = millis();

    showGPS();

    Serial.print(F("[ Satellites ]: "));
    Serial.println(gps.satellites.isValid() ? gps.satellites.value() : 0);

    Serial.print(F("[ Date/Time  ]: "));
    if (gps.date.isValid() && gps.time.isValid()) {
      Serial.print(gps.date.year());
      Serial.print("-");
      if (gps.date.month() < 10) Serial.print("0");
      Serial.print(gps.date.month());
      Serial.print("-");
      if (gps.date.day() < 10) Serial.print("0");
      Serial.print(gps.date.day());
      Serial.print(" ");

      if (gps.time.hour() < 10) Serial.print("0");
      Serial.print(gps.time.hour());
      Serial.print(":");

      if (gps.time.minute() < 10) Serial.print("0");
      Serial.print(gps.time.minute());
      Serial.print(":");

      if (gps.time.second() < 10) Serial.print("0");
      Serial.print(gps.time.second());

      Serial.println(" UTC");
    } else {
      Serial.println("Searching...");
    }

    Serial.print(F("[ Fix/Coords ]: "));
    if (gps.location.isValid()) {
      Serial.print("Lat: ");
      Serial.print(gps.location.lat(), 6);
      Serial.print(" | Lon: ");
      Serial.println(gps.location.lng(), 6);
    } else {
      Serial.println("NO FIX YET");
    }

    Serial.print(F("[ Altitude   ]: "));
    if (gps.altitude.isValid()) {
      Serial.print(gps.altitude.meters());
      Serial.println(" meters");
    } else {
      Serial.println("Searching...");
    }

    Serial.print(F("[ Speed      ]: "));
    if (gps.speed.isValid()) {
      Serial.print(gps.speed.kmph());
      Serial.println(" km/h");
    } else {
      Serial.println("Searching...");
    }

    Serial.print(F("[ Heading    ]: "));
    if (gps.course.isValid()) {
      Serial.print(gps.course.deg());
      Serial.println(" degrees");
    } else {
      Serial.println("Searching...");
    }

    if (gps.charsProcessed() < 10) {
      Serial.println(F(
        ">>> WARNING: No NMEA data received! Check GPS RX/TX pins. <<<"
      ));
    }

    Serial.println(F("---------------------------------------"));
  }
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

void showGPS() {
  // Clear the GPS display area
  tft.fillRect(0, 23, SCREEN_W, SCREEN_H - 23, COL_BG);

  // Title
  tft.setTextColor(COL_ACCENT, COL_BG);
  tft.setTextSize(2);
  tft.setCursor(8, 30);
  tft.print("GPS");

  // GPS fix status
  tft.setTextSize(1);
  tft.setCursor(8, 55);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("STATUS:");

  tft.setTextColor(
    gps.location.isValid() ? COL_GOOD : COL_HEART,
    COL_BG
  );

  if (gps.location.isValid()) {
    tft.print(" FIXED");
  } else {
    tft.print(" SEARCHING...");
  }

  // Satellites
  tft.setCursor(8, 72);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("SATELLITES:");

  tft.setTextColor(COL_TEXT, COL_BG);

  if (gps.satellites.isValid()) {
    tft.print(gps.satellites.value());
  } else {
    tft.print("0");
  }

  // Latitude
  tft.setCursor(8, 90);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("LAT:");

  tft.setTextColor(COL_TEXT, COL_BG);

  if (gps.location.isValid()) {
    tft.print(gps.location.lat(), 6);
  } else {
    tft.print("---");
  }

  // Longitude
  tft.setCursor(8, 106);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("LON:");

  tft.setTextColor(COL_TEXT, COL_BG);

  if (gps.location.isValid()) {
    tft.print(gps.location.lng(), 6);
  } else {
    tft.print("---");
  }

  // Speed
  tft.setCursor(175, 55);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("SPEED:");

  tft.setTextColor(COL_TEXT, COL_BG);

  if (gps.speed.isValid()) {
    tft.print(gps.speed.kmph(), 1);
    tft.print(" km/h");
  } else {
    tft.print("---");
  }

  // Altitude
  tft.setCursor(175, 72);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("ALT:");

  tft.setTextColor(COL_TEXT, COL_BG);

  if (gps.altitude.isValid()) {
    tft.print(gps.altitude.meters(), 1);
    tft.print(" m");
  } else {
    tft.print("---");
  }

  // Heading
  tft.setCursor(175, 90);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("HEADING:");

  tft.setTextColor(COL_TEXT, COL_BG);

  if (gps.course.isValid()) {
    tft.print(gps.course.deg(), 1);
    tft.print(" deg");
  } else {
    tft.print("---");
  }

  // UTC time
  tft.setCursor(175, 106);
  tft.setTextColor(COL_DIM, COL_BG);
  tft.print("UTC:");

  tft.setTextColor(COL_TEXT, COL_BG);

  if (gps.time.isValid()) {
    if (gps.time.hour() < 10) tft.print("0");
    tft.print(gps.time.hour());
    tft.print(":");

    if (gps.time.minute() < 10) tft.print("0");
    tft.print(gps.time.minute());
    tft.print(":");

    if (gps.time.second() < 10) tft.print("0");
    tft.print(gps.time.second());
  } else {
    tft.print("--:--:--");
  }
}