#include "material_sensors.h"
#include "board_config.h"

namespace {
using MaterialSensors::Reading;
constexpr unsigned long POLL_MS = 20;

Reading liquidLevels[] = {{-1, -1, false}, {-1, -1, false}};
unsigned long liquidAt[2] = {};
}

namespace MaterialSensors {
Reading liquid(uint8_t index, unsigned long now) {
  auto &value = liquidLevels[index];
  if (value.raw >= 0 && !Board::elapsed(now, liquidAt[index], POLL_MS)) return value;

  liquidAt[index] = now;
  const auto &cfg = Board::LIQUIDS[index];
  if (cfg.levelInput == Board::LevelInput::Analog) {
    const int16_t raw = analogRead(cfg.levelPin);
    const long percent = (static_cast<long>(raw) - cfg.emptyRaw) * 100
        / (static_cast<long>(cfg.fullRaw) - cfg.emptyRaw);
    const int8_t clamped = constrain(percent, 0L, 100L);
    value = {raw, clamped, clamped >= cfg.minPercent};
  } else {
    const int16_t raw = digitalRead(cfg.levelPin);
    value = {raw, -1, raw == (cfg.levelPresentHigh ? HIGH : LOW)};
  }
  return value;
}
}
