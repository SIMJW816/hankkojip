#pragma once

#include <Arduino.h>

namespace MaterialSensors {
struct Reading {
  int16_t raw;     // 수위 ADC 또는 디지털 입력값
  int8_t percent;  // 아날로그 잔량 추정치. 디지털 입력은 -1
  bool present;
};

Reading liquid(uint8_t index, unsigned long now);
}
