#pragma once

#include <Arduino.h>

// 배선표와 시험 기록에 맞춰 채웁니다. 보정과 정지 시험 전에는 ENABLE_DISPENSING을 끕니다.
namespace Board {
constexpr bool ENABLE_DISPENSING = false;
constexpr unsigned long BAUD = 115200;
constexpr int HX_DOUT = -1;
constexpr int HX_SCK = -1;
constexpr long EMPTY_PLATFORM_RAW = 0;
constexpr double COUNTS_PER_G = 0;  // 기준 추를 올렸을 때의 raw 차이 / 기준 추 g (부호 포함)
constexpr double CUP_MIN_G = 0;
constexpr double CUP_MAX_G = 0;
constexpr double MAX_TOTAL_G = 0;
constexpr double MAX_GROSS_G = 0;   // 빈 컵과 투입물의 합계 기준
constexpr double STABLE_BAND_G = 0;
constexpr unsigned long STABLE_MS = 0;
constexpr unsigned long SCALE_TIMEOUT_MS = 0;
constexpr unsigned long SETTLE_TIMEOUT_MS = 0;
constexpr unsigned long WATCHDOG_MS = 0;

inline bool elapsed(unsigned long now, unsigned long since, unsigned long duration) {
  return now - since >= duration;
}

inline bool configureOutput(int pin, bool high) {
#if defined(ARDUINO_AVR_UNO)
  digitalWrite(pin, high ? HIGH : LOW);
  pinMode(pin, OUTPUT);
  return true;
#else
  const uint32_t level = high ? IOPORT_CFG_PORT_OUTPUT_HIGH : IOPORT_CFG_PORT_OUTPUT_LOW;
  return R_IOPORT_PinCfg(&g_ioport_ctrl, g_pin_cfg[pin].pin,
                        IOPORT_CFG_PORT_DIRECTION_OUTPUT | level) == FSP_SUCCESS;
#endif
}

inline bool writeOutput(int pin, bool high) {
#if defined(ARDUINO_AVR_UNO)
  digitalWrite(pin, high ? HIGH : LOW);
  return true;
#else
  return R_IOPORT_PinWrite(&g_ioport_ctrl, g_pin_cfg[pin].pin,
                          high ? BSP_IO_LEVEL_HIGH : BSP_IO_LEVEL_LOW) == FSP_SUCCESS;
#endif
}

// 74HC595 두 개로 P1~P4 ULN2003의 IN1~IN4에 연결합니다.
constexpr int POWDER_DATA = -1;   // SER
constexpr int POWDER_CLOCK = -1;  // SRCLK
constexpr int POWDER_LATCH = -1;  // RCLK
constexpr int POWDER_OE = -1;     // 두 칩의 /OE, 외부 풀업으로 리셋 시 출력 차단

enum class LevelInput : uint8_t { Analog, Digital, DigitalPullup };

struct Powder {
  bool reverse;
  unsigned long intervalUs;   // ULN2003 반스텝 사이 시간(µs)
};

struct Liquid {
  int pumpPin, levelPin;
  bool pumpOnHigh, levelPresentHigh;
  LevelInput levelInput;
  uint16_t emptyRaw, fullRaw;  // Analog 모드의 실제 ADC 값. fullRaw < emptyRaw도 지원
  uint8_t minPercent;
};

constexpr Powder POWDERS[] = {{false, 0}, {false, 0}, {false, 0}, {false, 0}};
constexpr Liquid LIQUIDS[] = {
  {-1, -1, true, true, LevelInput::Analog, 0, 0, 0},
  {-1, -1, true, true, LevelInput::Analog, 0, 0, 0}
};

struct Slot {
  bool installed;
  double minG, maxG;
  double cutoffG;                // 잔류 낙하·액적을 반영하여 목표보다 먼저 멈추는 양
  double toleranceG;
  double flowIncreaseG;          // noFlowMs 동안 정상 배출에 필요한 최소 무게 증가량
  unsigned long noFlowMs, maxOnMs;
};

// 배열 순서는 P1, P2, P3, P4, L1, L2입니다. 재료 이름은 서버에서 관리합니다.
constexpr Slot UNWIRED = {false, 0, 0, 0, 0, 0, 0, 0};
#if defined(ARDUINO_AVR_UNO)
constexpr Slot SLOTS[] PROGMEM = {UNWIRED, UNWIRED, UNWIRED, UNWIRED, UNWIRED, UNWIRED};

inline Slot slot(size_t index) {
  Slot value;
  memcpy_P(&value, &SLOTS[index], sizeof(value));
  return value;
}
#else
constexpr Slot SLOTS[] = {UNWIRED, UNWIRED, UNWIRED, UNWIRED, UNWIRED, UNWIRED};

inline const Slot &slot(size_t index) {
  return SLOTS[index];
}
#endif
}
