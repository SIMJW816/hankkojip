#pragma once

#include <Arduino.h>

namespace PowderMotion {
bool begin();
bool stop();
void startDispensing();
bool dispenseStep(uint8_t slot);
}
