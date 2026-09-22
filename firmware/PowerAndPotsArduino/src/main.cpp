#include <Arduino.h>
#include "power-state-machine.hpp"

const byte POT_SINGLE_PIN = A3;
const byte POT_SINGLE_POWER_PIN = 15;

const byte POW_TRISTATE_PIN = A2;
const byte POT_VOLUME_PIN = A1;

const byte POWER_SW_PIN = 14;

const byte MUX_ANALOG_PIN = A0;
const byte MUX_SELECT_PIN = 7;

const byte MULTI_PUSH_SWITCH_PIN = 4;

const byte ROTARY_SWITCH_1_PIN = 8;
const byte ROTARY_SWITCH_2_PIN = 9;

struct PotPoint {
  int raw;
  int value;
};

const PotPoint POT_VOLUME_POINTS[] = {
  {547, 20},
  {878, 10},
  {978, 5},
  {1018, 2},
  {1023, 0},
};

const PotPoint POT_SINGLE_POINTS[] = {
  {0, 0},
  {1023, 20},
};

const PotPoint POT_BALANCE_POINTS[] = {
  {0, 20},
  {1023, 0},
};

const PotPoint POT_MULTI_SECOND_POINTS[] = {
  {0, 20},
  {318, 10},
  {533, 0},
};

const byte NUM_SAMPLES = 10;

int readAveraged(byte pin) {
  long sum = 0;
  for (byte i = 0; i < NUM_SAMPLES; i++) {
    sum += analogRead(pin);
  }
  return sum / NUM_SAMPLES;
}

bool readDigitalStable(byte pin) {
  byte highCount = 0;
  for (byte i = 0; i < NUM_SAMPLES; i++) {
    if (digitalRead(pin)) highCount++;
    delay(1);
  }
  return highCount > NUM_SAMPLES / 2;
}

template<byte N>
int scalePot(int reading, const PotPoint (&points)[N]) {
  if (reading <= points[0].raw) return points[0].value;
  for (byte i = 1; i < N; i++) {
    if (reading <= points[i].raw) {
      long span = points[i].raw - points[i - 1].raw;
      long num = (long)(reading - points[i - 1].raw) * (points[i].value - points[i - 1].value);
      return points[i - 1].value + (int)((num + (num >= 0 ? span / 2 : -span / 2)) / span);
    }
  }
  return points[N - 1].value;
}

const unsigned long REPORT_INTERVAL_MS = 250;
const int NEVER = -9999;

struct ReportedValue {
  int value = NEVER;
  unsigned long lastMs = -REPORT_INTERVAL_MS;
};

bool throttleReport(ReportedValue &v, int reading, int threshold) {
  if ((v.value == NEVER || abs(reading - v.value) > threshold) &&
      millis() - v.lastMs >= REPORT_INTERVAL_MS) {
    v.value = reading;
    v.lastMs = millis();
    return true;
  }
  return false;
}

void report(const char *name, int value) {
  Serial.print(name);
  Serial.println(value);
}

void report(const char *name, const char *value) {
  Serial.print(name);
  Serial.println(value);
}

void reportPot(const char *name, int value, int raw) {
  Serial.print(name);
  Serial.print(value);
  Serial.print(" (raw ");
  Serial.print(raw);
  Serial.println(")");
}

ReportedValue potVolume, potSingle, potBalance, potMultiSecond, powTristate, powSw, multiPush, rotary;

void setup() {
  Serial.begin(9600);

  pinMode(POWER_SW_PIN, INPUT);
  pinMode(MULTI_PUSH_SWITCH_PIN, INPUT_PULLUP);
  pinMode(ROTARY_SWITCH_1_PIN, INPUT_PULLUP);
  pinMode(ROTARY_SWITCH_2_PIN, INPUT_PULLUP);

  pinMode(POT_SINGLE_POWER_PIN, OUTPUT);
  digitalWrite(POT_SINGLE_POWER_PIN, LOW);

  pinMode(MUX_SELECT_PIN, OUTPUT);

  setupPower();
}

void loop() {
  digitalWrite(POT_SINGLE_POWER_PIN, HIGH);

  delayMicroseconds(300);

  int potSingleRaw = readAveraged(POT_SINGLE_PIN);
  int potSingleReading = scalePot(potSingleRaw, POT_SINGLE_POINTS);

  int powTristateRaw = readAveraged(POW_TRISTATE_PIN);
  int powTristateState = powTristateRaw > 500 ? 2 : powTristateRaw > 100 ? 1 : 0;
  bool powSwReading = readDigitalStable(POWER_SW_PIN);
  handlePowerSwitch(powSwReading);

  int potVolumeRaw = readAveraged(POT_VOLUME_PIN);
  int potVolumeReading = scalePot(potVolumeRaw, POT_VOLUME_POINTS);

  digitalWrite(MUX_SELECT_PIN, LOW);
  delayMicroseconds(50);
  int multiSecondPotRaw = readAveraged(MUX_ANALOG_PIN);
  int multiSecondPotReading = scalePot(multiSecondPotRaw, POT_MULTI_SECOND_POINTS);
  delayMicroseconds(50);
  digitalWrite(MUX_SELECT_PIN, HIGH);
  int balancePotRaw = readAveraged(MUX_ANALOG_PIN);
  int balancePotReading = scalePot(balancePotRaw, POT_BALANCE_POINTS);

  bool multiPushSwitch = readDigitalStable(MULTI_PUSH_SWITCH_PIN);
  bool rotarySwitch1 = readDigitalStable(ROTARY_SWITCH_1_PIN);
  bool rotarySwitch2 = readDigitalStable(ROTARY_SWITCH_2_PIN);

  digitalWrite(POT_SINGLE_POWER_PIN, LOW);

  int rotaryState = !rotarySwitch1 ? 1 : (!rotarySwitch2 ? 2 : 0);

  bool reported = false;

  if (throttleReport(potVolume, potVolumeReading, 0)) {
    reportPot("POT volume: ", potVolume.value, potVolumeRaw);
    reported = true;
  }

  if (throttleReport(potSingle, potSingleReading, 0)) {
    reportPot("POT single: ", potSingle.value, potSingleRaw);
    reported = true;
  }

  if (throttleReport(potBalance, balancePotReading, 0)) {
    reportPot("POT balance: ", potBalance.value, balancePotRaw);
    reported = true;
  }

  if (throttleReport(potMultiSecond, multiSecondPotReading, 0)) {
    reportPot("POT multi second: ", potMultiSecond.value, multiSecondPotRaw);
    reported = true;
  }

  if (throttleReport(powTristate, powTristateState, 0)) {
    report("POWER tristate: ", powTristate.value == 2 ? "RIGHT" : powTristate.value == 1 ? "LEFT" : "CENTER");
    reported = true;
  }

  if (throttleReport(powSw, powSwReading ? 1 : 0, 0)) {
    report("POWER switch: ", powSw.value ? "ON" : "OFF");
    reported = true;
  }

  if (throttleReport(multiPush, multiPushSwitch ? 1 : 0, 0)) {
    report("MULTI PUSH switch: ", multiPush.value ? "OFF" : "ON");
    reported = true;
  }

  if (throttleReport(rotary, rotaryState, 0)) {
    report("MULTI ROTARY switch: ", rotary.value == 1 ? "SW1" : rotary.value == 2 ? "SW2" : "OFF");
    reported = true;
  }

  if (reported) {
    Serial.println("-----------------------------------------");
  }

  delay(100);
}
