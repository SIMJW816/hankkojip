#include "powder_motion.h"
#include "board_config.h"

namespace {
// 각 4비트 묶음의 하위 비트부터 ULN2003 IN1, IN2, IN3, IN4 순서입니다.
constexpr uint8_t HALF_STEPS[] = {0x1, 0x3, 0x2, 0x6, 0x4, 0xC, 0x8, 0x9};
uint8_t nextPhase[sizeof(Board::POWDERS) / sizeof(Board::POWDERS[0])] = {};
unsigned long lastStep = 0;
bool initialized = false, enabled = false;

void writeCoils(uint16_t mask) {
  digitalWrite(Board::POWDER_LATCH, LOW);
  shiftOut(Board::POWDER_DATA, Board::POWDER_CLOCK, MSBFIRST, highByte(mask));
  shiftOut(Board::POWDER_DATA, Board::POWDER_CLOCK, MSBFIRST, lowByte(mask));
  digitalWrite(Board::POWDER_LATCH, HIGH);
}
}

namespace PowderMotion {
bool begin() {
  if (!Board::configureOutput(Board::POWDER_OE, true)
      || !Board::configureOutput(Board::POWDER_LATCH, false)
      || !Board::configureOutput(Board::POWDER_CLOCK, false)
      || !Board::configureOutput(Board::POWDER_DATA, false)) return false;
  writeCoils(0);
  initialized = true;
  return true;
}

bool stop() {
  if (!initialized) return false;
  if (!Board::writeOutput(Board::POWDER_OE, true)) return false;
  if (enabled) writeCoils(0);
  enabled = false;
  return true;
}

void startDispensing() {
  lastStep = micros();
}

bool dispenseStep(uint8_t slot) {
  const auto &cfg = Board::POWDERS[slot];
  const unsigned long now = micros();
  if (!Board::elapsed(now, lastStep, cfg.intervalUs)) return true;
  lastStep = now;
  auto &phase = nextPhase[slot];
  const uint16_t mask = static_cast<uint16_t>(HALF_STEPS[phase]) << (4 * slot);
  writeCoils(mask);
  phase = (phase + (cfg.reverse ? 7 : 1)) & 7;
  if (!enabled) enabled = Board::writeOutput(Board::POWDER_OE, false);
  return enabled;
}
}
