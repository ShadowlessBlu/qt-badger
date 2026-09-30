#define BUTTON_1_PIN 4
#define BUTTON_2_PIN 6

void setup() {
  Serial.begin(9600);
  
  // Initialize with internal pull-up resistors
  pinMode(BUTTON_1_PIN, INPUT_PULLUP);
  pinMode(BUTTON_2_PIN, INPUT_PULLUP);
  
  Serial.println("System Ready. Press buttons to test...");
}

void loop() {
  int btn1State = digitalRead(BUTTON_1_PIN);
  int btn2State = digitalRead(BUTTON_2_PIN);
  
  // Print raw values: 1 = Not Pressed (HIGH), 0 = Pressed (LOW)
  Serial.print("Button 1 (Pin 4): ");
  Serial.print(btn1State);
  Serial.print(" | Button 2 (Pin 6): ");
  Serial.println(btn2State);
  
  delay(200); // Small delay to make the monitor readable
}
