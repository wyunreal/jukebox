#pragma once

#include <Arduino.h>

const byte RELAY_PIN = 2;
// modulo de relay active-low: se activa con LOW
const byte RELAY_ON = LOW;
const byte RELAY_OFF = HIGH;
const unsigned long POWER_LONG_PRESS_MS = 5000;

bool powerOn = false;
bool prevPowerSw = false;
bool longPressFired = false;
unsigned long powerSwPressMs = 0;

void setupPower() {
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, RELAY_OFF);
}

void handlePowerSwitch(bool pressed) {
  if (pressed && !prevPowerSw) {
    powerSwPressMs = millis();
    longPressFired = false;
  } else if (pressed && powerOn && !longPressFired &&
             millis() - powerSwPressMs >= POWER_LONG_PRESS_MS) {
    longPressFired = true;
    powerOn = false;
    Serial.println("POWER: hard off");
    digitalWrite(RELAY_PIN, RELAY_OFF);
  } else if (!pressed && prevPowerSw && !longPressFired) {
    if (!powerOn) {
      powerOn = true;
      Serial.println("POWER: ON");
      digitalWrite(RELAY_PIN, RELAY_ON);
    } else {
      Serial.println("POWER: soft off");
    }
  }
  prevPowerSw = pressed;
}
