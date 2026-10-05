#pragma once

#include <Arduino.h>

const byte RELAY_PIN = 2;
const byte RELAY_ON = LOW;
const byte RELAY_OFF = HIGH;
const unsigned long POWER_LONG_PRESS_MS = 5000;

// Delay between a "POWER: off" command from the host and the relay cut.
// The host (the Pi) is gone by then, but this board keeps running from 5VSB,
// so it is the only side that can wait: the daemon sends the message just
// before it shuts the Pi down, this timer lets the Pi finish halting, and the
// relay is cut afterwards. A number in the command ("POWER: off 45") overrides
// it, so the delay can be tuned from the host without reflashing.
const unsigned long POWER_OFF_DELAY_MS = 30000;

bool powerOn = false;
bool prevPowerSw = false;
bool longPressFired = false;
unsigned long powerSwPressMs = 0;

// A relay cut armed by the host, cut when millis() reaches relayOffAtMs.
bool relayOffPending = false;
unsigned long relayOffAtMs = 0;

void setupPower() {
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, RELAY_OFF);
}

void cutRelay() {
  powerOn = false;
  digitalWrite(RELAY_PIN, RELAY_OFF);
}

// Accepts the host's power line. "POWER: off" arms a delayed relay cut after
// POWER_OFF_DELAY_MS; "POWER: off N" waits N seconds instead (N may be 0 for
// an immediate cut); "POWER: cancel" disarms a pending cut (used if the host
// could not actually shut itself down). Anything else is ignored.
void handlePowerCommand(const char *line) {
  if (strncmp(line, "POWER: cancel", 13) == 0) {
    if (relayOffPending) {
      relayOffPending = false;
      Serial.println("POWER: off cancelled");
    }
    return;
  }
  if (strncmp(line, "POWER: off", 10) != 0) return;
  unsigned long delayMs = POWER_OFF_DELAY_MS;
  const char *p = line + 10;
  while (*p == ' ') p++;
  if (*p >= '0' && *p <= '9') {
    delayMs = strtoul(p, NULL, 10) * 1000UL;
  }
  relayOffPending = true;
  relayOffAtMs = millis() + delayMs;
  Serial.print("POWER: off in ");
  Serial.print(delayMs / 1000UL);
  Serial.println("s");
}

// Called every loop; performs the armed relay cut when its time arrives.
void servicePowerOff() {
  if (relayOffPending && (long)(millis() - relayOffAtMs) >= 0) {
    relayOffPending = false;
    Serial.println("POWER: hard off");
    cutRelay();
  }
}

void handlePowerSwitch(bool pressed) {
  if (pressed && !prevPowerSw) {
    powerSwPressMs = millis();
    longPressFired = false;
  } else if (pressed && powerOn && !longPressFired &&
             millis() - powerSwPressMs >= POWER_LONG_PRESS_MS) {
    longPressFired = true;
    if (relayOffPending) {
      relayOffPending = false;
      Serial.println("POWER: off cancelled");
    }
    Serial.println("POWER: hard off");
    cutRelay();
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
