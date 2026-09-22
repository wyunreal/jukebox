#include <Arduino.h>

const uint8_t ROW_PINS[4] = {2, 3, 4, 5};
const uint8_t COL_PINS[4] = {6, 7, 8, 9};
const unsigned long DEBOUNCE_MS = 20;
const unsigned long LONG_PRESS_MS = 1000;
const unsigned long REPEAT_MS = 500;

struct KeyState {
  bool pressed;
  unsigned long lastChange;
  unsigned long downTime;
  unsigned long lastRepeat;
};

KeyState keys[4][4] = {};

void emit(const __FlashStringHelper *evt, uint8_t r, uint8_t c) {
  Serial.print(evt);
  Serial.print(' ');
  Serial.print(r + 1);
  Serial.print(' ');
  Serial.println(c + 1);
}

void setup() {
  Serial.begin(9600);
  for (uint8_t r = 0; r < 4; r++) {
    pinMode(ROW_PINS[r], OUTPUT);
    digitalWrite(ROW_PINS[r], HIGH);
  }
  for (uint8_t c = 0; c < 4; c++) pinMode(COL_PINS[c], INPUT_PULLUP);
}

void loop() {
  unsigned long now = millis();
  for (uint8_t r = 0; r < 4; r++) {
    for (uint8_t i = 0; i < 4; i++) digitalWrite(ROW_PINS[i], HIGH);
    digitalWrite(ROW_PINS[r], LOW);
    delayMicroseconds(10);
    for (uint8_t c = 0; c < 4; c++) {
      KeyState &k = keys[r][c];
      bool raw = digitalRead(COL_PINS[c]) == LOW;
      if (raw != k.pressed && now - k.lastChange >= DEBOUNCE_MS) {
        k.pressed = raw;
        k.lastChange = now;
        if (raw) {
          k.downTime = now;
          k.lastRepeat = now;
          emit(F("DOWN"), r, c);
        } else {
          emit(F("UP"), r, c);
          emit(now - k.downTime < LONG_PRESS_MS ? F("PRESS") : F("LONG_PRESS"), r, c);
        }
      } else if (k.pressed && now - k.lastRepeat >= REPEAT_MS) {
        k.lastRepeat = now;
        emit(F("PRESSED"), r, c);
      }
    }
  }
}
