#include <TinyGPSPlus.h>   // Library Manager: "TinyGPSPlus" by Mikal Hart

// On UNO Q, use hardware Serial1 for pins 0 and 1.
// Legacy SoftwareSerial is not compatible.
#define gpsSerial Serial1 

TinyGPSPlus gps;
unsigned long lastPrint = 0;

void setup() {
  // Initialize standard Serial Monitor connection
  Serial.begin(9600);      
  
  // Initialize communication with the ATGM336H GPS module
  gpsSerial.begin(9600);   
  
  Serial.println(F("--- UNO Q Extended ATGM336H GPS Test ---"));
  Serial.println(F("Ensure you have a clear sky view for a valid fix."));
  Serial.println();
}

void loop() {
  // Read hardware serial data from the GPS module
  while (gpsSerial.available()) {
    gps.encode(gpsSerial.read());
  }

  // Print all metrics every 1 second
  if (millis() - lastPrint > 1000) {
    lastPrint = millis();

    Serial.print(F("[ Satellites ]: "));
    Serial.println(gps.satellites.isValid() ? gps.satellites.value() : 0);

    // 1. DATE & TIME (UTC)
    Serial.print(F("[ Date/Time  ]: "));
    if (gps.date.isValid() && gps.time.isValid()) {
      // Format: YYYY-MM-DD HH:MM:SS
      Serial.print(gps.date.year());   Serial.print(F("-"));
      if (gps.date.month() < 10) Serial.print(F("0"));
      Serial.print(gps.date.month());  Serial.print(F("-"));
      if (gps.date.day() < 10) Serial.print(F("0"));
      Serial.print(gps.date.day());    Serial.print(F(" "));
      
      if (gps.time.hour() < 10) Serial.print(F("0"));
      Serial.print(gps.time.hour());   Serial.print(F(":"));
      if (gps.time.minute() < 10) Serial.print(F("0"));
      Serial.print(gps.time.minute()); Serial.print(F(":"));
      if (gps.time.second() < 10) Serial.print(F("0"));
      Serial.print(gps.time.second());
      Serial.println(F(" UTC"));
    } else {
      Serial.println(F("Searching..."));
    }

    // 2. LOCATION COORDINATES
    Serial.print(F("[ Fix/Coords ]: "));
    if (gps.location.isValid()) {
      Serial.print(F("Lat: "));
      Serial.print(gps.location.lat(), 6);
      Serial.print(F(" | Lon: "));
      Serial.println(gps.location.lng(), 6);
    } else {
      Serial.println(F("NO FIX YET"));
    }

    // 3. ALTITUDE
    Serial.print(F("[ Altitude   ]: "));
    if (gps.altitude.isValid()) {
      Serial.print(gps.altitude.meters());
      Serial.println(F(" meters"));
    } else {
      Serial.println(F("Searching..."));
    }

    // 4. SPEED
    Serial.print(F("[ Speed      ]: "));
    if (gps.speed.isValid()) {
      Serial.print(gps.speed.kmph());
      Serial.println(F(" km/h"));
    } else {
      Serial.println(F("Searching..."));
    }

    // 5. COURSE/HEADING
    Serial.print(F("[ Heading    ]: "));
    if (gps.course.isValid()) {
      Serial.print(gps.course.deg());
      Serial.println(F(" degrees"));
    } else {
      Serial.println(F("Searching..."));
    }

    // DIAGNOSTIC CHECK
    if (gps.charsProcessed() < 10) {
      Serial.println(F("\n>>> WARNING: No NMEA data received at all! Check your RX/TX pins. <<<"));
    }
    
    Serial.println(F("---------------------------------------"));
  }
}
