#include <ArduinoJson.h>
#if defined(ARDUINO_AVR_UNO) && ARDUINOJSON_VERSION_MAJOR != 6
#error "Uno R3 requires ArduinoJson 6.21.5. Select it in Arduino IDE Library Manager."
#endif
#include "board_config.h"
#include "material_sensors.h"
#include "powder_motion.h"

constexpr size_t SLOT_COUNT = 6;
constexpr size_t POWDER_COUNT = 4;
using Board::elapsed;
#if defined(ARDUINO_AVR_UNO)
auto &deviceSerial = Serial;
// Flask의 v1 START는 6개 슬롯과 최대 32비트 순번을 넣어도 384바이트 이내입니다.
constexpr size_t FRAME_LIMIT = 384;
#else
auto &deviceSerial = Serial1;
constexpr size_t FRAME_LIMIT = 1536;
#endif
constexpr unsigned long FRAME_GAP_MS = 150;
static_assert(sizeof(Board::SLOTS) / sizeof(Board::SLOTS[0]) == SLOT_COUNT, "slot count");
static_assert(sizeof(Board::POWDERS) / sizeof(Board::POWDERS[0]) == POWDER_COUNT, "powder count");
static_assert(sizeof(Board::LIQUIDS) / sizeof(Board::LIQUIDS[0]) == SLOT_COUNT - POWDER_COUNT,
              "liquid count");

enum class Phase : uint8_t {
  Idle, Taring, Dispensing, Settling, Stopping, Completed, Stopped, Error
};

struct Item {
  uint8_t slot;
  double targetG;
  double actualG;
  bool measured;
  bool done;
};

struct Job {
  char id[33] = "";
  Phase phase = Phase::Idle;
  const __FlashStringHelper *error = nullptr;
  Item items[SLOT_COUNT] = {};
  uint8_t count = 0;
  uint8_t index = 0;
  double tare = 0;
  double baseline = 0;
  double flowReference = 0;
  unsigned long phaseAt = 0;
  unsigned long flowAt = 0;
};

Job job;
bool scaleWired = false, configured = false;
bool outputFault = false, hasPowder = false;
bool haveRaw = false, haveStableRange = false;
long rawReading = 0;
double grossG = 0, stableReference = 0;
unsigned long sampledAt = 0, stableAt = 0, heartbeatAt = 0;
char session[33] = "";
uint32_t lastSequence = 0, lastStatusSequence = 0, pendingStatus = 0;
unsigned long lastStatusAt = 0;
char input[FRAME_LIMIT];
size_t inputSize = 0;
bool inputOverflow = false;
unsigned long inputAt = 0;

bool active() {
  return job.phase >= Phase::Taring && job.phase <= Phase::Stopping;
}

const __FlashStringHelper *phaseName() {
  switch (job.phase) {
    case Phase::Taring: return F("taring");
    case Phase::Dispensing: return F("dispensing");
    case Phase::Settling: return F("settling");
    case Phase::Stopping: return F("stopping");
    case Phase::Completed: return F("completed");
    case Phase::Stopped: return F("stopped");
    case Phase::Error: return F("error");
    default: return F("idle");
  }
}

bool headerPin(int pin) {
  // D0/D1은 UART용입니다. A0~A5의 디지털 번호는 14~19입니다.
  return pin >= 2 && pin <= 19;
}

bool claimPin(int pin, uint32_t &used) {
  if (!headerPin(pin) || (used & (1UL << pin))) return false;
  used |= 1UL << pin;
  return true;
}

bool claimOutput(int pin, uint32_t &used) {
  // D13은 부트로더가 내장 LED 신호를 내보낼 수 있습니다.
  return pin != LED_BUILTIN && claimPin(pin, used);
}

bool positive(double value) {
  return isfinite(value) && value > 0;
}

bool scalePinsValid() {
  uint32_t used = 0;
  if (!claimPin(Board::HX_DOUT, used) || !claimOutput(Board::HX_SCK, used)) return false;
  // 설정이 불완전한 상태에서도 HX711 확인용 신호가 배출 출력으로 전달되지 않게 합니다.
  const int powderPins[] = {Board::POWDER_DATA, Board::POWDER_CLOCK, Board::POWDER_LATCH, Board::POWDER_OE};
  for (int pin : powderPins) {
    if (headerPin(pin) && (used & (1UL << pin))) return false;
  }
  for (const auto &liquid : Board::LIQUIDS) {
    if ((headerPin(liquid.pumpPin) && (used & (1UL << liquid.pumpPin)))
        || (headerPin(liquid.levelPin) && (used & (1UL << liquid.levelPin)))) return false;
  }
  return true;
}

bool liquidValid(size_t idx, uint32_t &used) {
  const auto &cfg = Board::LIQUIDS[idx - POWDER_COUNT];
  if (!claimOutput(cfg.pumpPin, used) || !claimPin(cfg.levelPin, used)) return false;
  if (cfg.levelInput == Board::LevelInput::Analog) {
    return cfg.levelPin >= A0 && cfg.levelPin <= A5 && cfg.emptyRaw <= 1023 && cfg.fullRaw <= 1023
        && cfg.emptyRaw != cfg.fullRaw && cfg.minPercent > 0 && cfg.minPercent <= 100;
  }
  return true;
}

bool configurationValid() {
  if (!Board::ENABLE_DISPENSING || !scaleWired || !positive(fabs(Board::COUNTS_PER_G))
      || !positive(Board::CUP_MIN_G) || !positive(Board::CUP_MAX_G)
      || Board::CUP_MAX_G < Board::CUP_MIN_G || !positive(Board::MAX_TOTAL_G)
      || !positive(Board::MAX_GROSS_G) || Board::MAX_GROSS_G < Board::CUP_MAX_G + Board::MAX_TOTAL_G
      || !positive(Board::STABLE_BAND_G) || !Board::STABLE_MS || !Board::SCALE_TIMEOUT_MS
      || Board::SETTLE_TIMEOUT_MS <= Board::STABLE_MS || !Board::WATCHDOG_MS) return false;
  uint32_t used = 0;
  if (!claimPin(Board::HX_DOUT, used) || !claimOutput(Board::HX_SCK, used)) return false;
  size_t count = 0;
  for (size_t idx = 0; idx < SLOT_COUNT; ++idx) {
    const auto &slot = Board::slot(idx);
    if (!slot.installed) continue;
    if (!positive(slot.minG) || !positive(slot.maxG) || slot.minG > slot.maxG
        || slot.maxG > Board::MAX_TOTAL_G || !isfinite(slot.cutoffG)
        || slot.cutoffG < 0 || slot.cutoffG >= slot.minG || !positive(slot.toleranceG)
        || !positive(slot.flowIncreaseG) || !slot.noFlowMs || slot.noFlowMs > slot.maxOnMs) return false;
    if (idx < POWDER_COUNT) {
      if (!Board::POWDERS[idx].intervalUs) return false;
      hasPowder = true;
    } else if (!liquidValid(idx, used)) {
      return false;
    }
    ++count;
  }
  return count > 0 && (!hasPowder || (claimOutput(Board::POWDER_DATA, used)
      && claimOutput(Board::POWDER_CLOCK, used) && claimOutput(Board::POWDER_LATCH, used)
      && claimOutput(Board::POWDER_OE, used)));
}

bool liquidPresent(size_t slot, unsigned long now) {
  return MaterialSensors::liquid(slot - POWDER_COUNT, now).present;
}

bool setPump(size_t slot, bool on) {
  const auto &cfg = Board::LIQUIDS[slot - POWDER_COUNT];
  return Board::writeOutput(cfg.pumpPin, on == cfg.pumpOnHigh);
}

bool allOff() {
  if (!configured) return true;
  bool safe = !hasPowder || PowderMotion::stop();
  for (size_t i = POWDER_COUNT; i < SLOT_COUNT; ++i) {
    if (Board::slot(i).installed && !setPump(i, false)) safe = false;
  }
  return safe;
}

void sampleScale(unsigned long now) {
  if (!scaleWired || digitalRead(Board::HX_DOUT) != LOW) return;
  uint32_t bits = 0;
  // HX711: 24비트와 A채널 gain=128 선택 펄스. DOUT을 기다리는 반복문은 두지 않습니다.
  // SCK가 낮을 때 UART 인터럽트를 허용합니다.
  for (int bit = 0; bit < 24; ++bit) {
    noInterrupts();
    digitalWrite(Board::HX_SCK, HIGH);
    delayMicroseconds(1);
    bits = (bits << 1) | (digitalRead(Board::HX_DOUT) == HIGH ? 1 : 0);
    digitalWrite(Board::HX_SCK, LOW);
    interrupts();
    delayMicroseconds(1);
  }
  noInterrupts();
  digitalWrite(Board::HX_SCK, HIGH);
  delayMicroseconds(1);
  digitalWrite(Board::HX_SCK, LOW);
  interrupts();
  delayMicroseconds(1);
  const bool released = digitalRead(Board::HX_DOUT) == HIGH;
  if (!released || bits == 0x800000 || bits == 0x7fffff) {
    haveRaw = haveStableRange = false;
    return;
  }
  rawReading = static_cast<long>(bits) - ((bits & 0x800000) ? 0x1000000L : 0);
  if (!haveRaw || elapsed(now, sampledAt, Board::SCALE_TIMEOUT_MS)) haveStableRange = false;
  haveRaw = true;
  sampledAt = now;
  if (!configured) return;
  grossG = (static_cast<double>(rawReading) - Board::EMPTY_PLATFORM_RAW) / Board::COUNTS_PER_G;
  if (!isfinite(grossG)) {
    haveRaw = haveStableRange = false;
  } else if (!haveStableRange || fabs(grossG - stableReference) > Board::STABLE_BAND_G) {
    stableReference = grossG;
    stableAt = now;
    haveStableRange = true;
  }
}

bool scaleFresh(unsigned long now) {
  return haveRaw && !elapsed(now, sampledAt, Board::SCALE_TIMEOUT_MS);
}

bool stable() {
  return haveStableRange && elapsed(sampledAt, stableAt, Board::STABLE_MS);
}

bool emptyCup() {
  return grossG >= Board::CUP_MIN_G && grossG <= Board::CUP_MAX_G;
}

bool ready(unsigned long now) {
  return configured && !outputFault && !active() && scaleFresh(now) && stable() && emptyCup();
}

void setPhase(Phase phase, unsigned long now) {
  job.phase = phase;
  job.phaseAt = now;
}

void finish(Phase phase, const __FlashStringHelper *error = nullptr) {
  if (!allOff()) {
    outputFault = true;
    phase = Phase::Error;
    error = F("OUTPUT");
  }
  job.phase = phase;
  job.error = error;
}

double itemWeight() {
  return max(0.0, grossG - job.baseline);
}

void beginSlot(unsigned long now) {
  const auto slot = job.items[job.index].slot;
  job.baseline = job.flowReference = grossG;
  job.flowAt = now;
  if (slot < POWDER_COUNT) {
    PowderMotion::startDispensing();
  } else if (!liquidPresent(slot, now)) {
    finish(Phase::Error, F("MATERIAL"));
    return;
  } else if (!setPump(slot, true)) {
    finish(Phase::Error, F("OUTPUT"));
    return;
  }
  setPhase(Phase::Dispensing, now);
}

void updateDispensing(const Item &item, unsigned long now) {
  const auto &cfg = Board::slot(item.slot);
  const bool powder = item.slot < POWDER_COUNT;
  if (itemWeight() >= item.targetG - cfg.cutoffG) {
    if (!allOff()) {
      outputFault = true;
      finish(Phase::Error, F("OUTPUT"));
      return;
    }
    setPhase(Phase::Settling, now);
    haveStableRange = false;
    return;
  }
  if (!powder && !liquidPresent(item.slot, now)) {
    finish(Phase::Error, F("MATERIAL"));
    return;
  }
  if (elapsed(now, job.phaseAt, cfg.maxOnMs)) {
    finish(Phase::Error, F("DISPENSE_TIMEOUT"));
    return;
  }
  if (grossG - job.flowReference >= cfg.flowIncreaseG) {
    job.flowReference = grossG;
    job.flowAt = now;
  } else if (elapsed(now, job.flowAt, cfg.noFlowMs)) {
    finish(Phase::Error, F("NO_FLOW"));
    return;
  }
  if (powder && !PowderMotion::dispenseStep(item.slot)) finish(Phase::Error, F("OUTPUT"));
}

void updateJob(unsigned long now) {
  if (!active()) return;
  if (elapsed(now, heartbeatAt, Board::WATCHDOG_MS)) {
    finish(Phase::Error, F("WATCHDOG"));
    return;
  }
  if (!scaleFresh(now)) {
    finish(Phase::Error, F("SCALE"));
    return;
  }
  const bool taring = job.phase == Phase::Taring;
  if (grossG < Board::CUP_MIN_G || (taring && !emptyCup())
      || (!taring && grossG < job.baseline - Board::STABLE_BAND_G)) {
    finish(Phase::Error, F("CUP"));
    return;
  }
  if (grossG > Board::MAX_GROSS_G || (!taring && grossG - job.tare > Board::MAX_TOTAL_G)) {
    finish(Phase::Error, F("OVERWEIGHT"));
    return;
  }

  Item &item = job.items[job.index];
  if (job.phase == Phase::Dispensing) {
    updateDispensing(item, now);
    return;
  }
  if (!stable()) {
    if (elapsed(now, job.phaseAt, Board::SETTLE_TIMEOUT_MS)) finish(Phase::Error, F("UNSTABLE"));
    return;
  }
  if (taring) {
    job.tare = grossG;
    beginSlot(now);
    return;
  }

  item.measured = true;
  item.actualG = itemWeight();
  if (job.phase == Phase::Stopping) {
    finish(Phase::Stopped);
  } else if (fabs(item.actualG - item.targetG) > Board::slot(item.slot).toleranceG) {
    finish(Phase::Error, F("OUT_OF_TOLERANCE"));
  } else {
    item.done = true;
    if (++job.index == job.count) finish(Phase::Completed);
    else beginSlot(now);
  }
}

bool isId(const char *value) {
  if (!value || strlen(value) != 32) return false;
  for (size_t i = 0; i < 32; ++i) {
    const char c = value[i];
    if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) return false;
  }
  return true;
}

int slotIndex(const char *name) {
  if (!name || !name[0] || !name[1] || name[2]) return -1;
  if (name[1] < '1' || name[1] > '9') return -1;
  const size_t number = name[1] - '1';
  if (name[0] == 'P' && number < POWDER_COUNT) return number;
  if (name[0] == 'L' && number < SLOT_COUNT - POWDER_COUNT) return POWDER_COUNT + number;
  return -1;
}

void startJob(const char *id, JsonArrayConst entries, bool recentStatus, unsigned long now) {
  if (active() || !strcmp(id, job.id)) return;
  strcpy(job.id, id);
  job.count = job.index = 0;
  job.phase = Phase::Idle;
  job.error = nullptr;
  if (!recentStatus || !ready(now)) {
    finish(Phase::Error, F("NOT_READY"));
    return;
  }
  if (entries.size() == 0 || entries.size() > SLOT_COUNT) {
    finish(Phase::Error, F("BAD_PLAN"));
    return;
  }
  uint8_t seen = 0;
  double total = 0;
  size_t count = 0;
  for (JsonVariantConst entry : entries) {
    const int index = slotIndex(entry[F("slot")].as<const char *>());
    const auto targetValue = entry[F("target_g")];
    const double target = targetValue.as<double>();
    if (index < 0 || (seen & (1U << index)) || !targetValue.is<double>()
        || !positive(target)) {
      finish(Phase::Error, F("BAD_PLAN"));
      return;
    }
    const auto &limits = Board::slot(index);
    if (!limits.installed || target < limits.minG || target > limits.maxG) {
      finish(Phase::Error, F("BAD_PLAN"));
      return;
    }
    if (index >= static_cast<int>(POWDER_COUNT) && !liquidPresent(index, now)) {
      finish(Phase::Error, F("MATERIAL"));
      return;
    }
    job.items[count++] = {static_cast<uint8_t>(index), target, 0, false, false};
    total += target;
    seen |= 1U << index;
  }
  if (total > Board::MAX_TOTAL_G) {
    finish(Phase::Error, F("BAD_PLAN"));
    return;
  }
  job.count = count;
  setPhase(Phase::Taring, now);
  heartbeatAt = now;
  haveStableRange = false;
}

void stopJob(unsigned long now) {
  if (!active() || job.phase == Phase::Stopping) return;
  if (!allOff()) {
    outputFault = true;
    finish(Phase::Error, F("OUTPUT"));
    return;
  }
  if (job.phase == Phase::Taring) {
    finish(Phase::Stopped);
  } else {
    setPhase(Phase::Stopping, now);
    haveStableRange = false;
  }
}

void serviceDevice() {
  const unsigned long now = millis();
  sampleScale(now);
  updateJob(now);
}

class StatusWriter : public Print {
 public:
  size_t write(uint8_t byte) override {
    // 프레임 전송 중에도 중량·재료·통신 제한 시간을 확인합니다.
    serviceDevice();
#if defined(ARDUINO_AVR_UNO)
    while (!deviceSerial.availableForWrite()) serviceDevice();
#endif
    return deviceSerial.write(byte);
  }

  template <typename Text>
  void quoted(Text value) {
    write('"');
    print(value);  // 검증된 ID나 고정 문자열만 전달합니다.
    write('"');
  }
};

void printBool(Print &out, bool value) {
  out.print(value ? F("true") : F("false"));
}

void printSlot(Print &out, size_t slot) {
  out.write('"');
  out.write(slot < POWDER_COUNT ? 'P' : 'L');
  out.write('1' + (slot < POWDER_COUNT ? slot : slot - POWDER_COUNT));
  out.write('"');
}

void printWeight(Print &out, double weight) {
#if ARDUINOJSON_VERSION_MAJOR == 6
  StaticJsonDocument<0> number;
#else
  JsonDocument number;
#endif
  number.set(weight);
  serializeJson(number, out);
}

#if defined(ARDUINO_AVR_UNO)
// 상태 복사본의 스택이 명령 파서와 겹치지 않도록 별도 프레임을 유지합니다.
__attribute__((noinline))
#endif
void statusReply(uint32_t sequence, unsigned long now) {
  // 전송 중 장치 상태가 바뀌어도 한 프레임 안에는 같은 시점의 값을 담습니다.
  const Job snapshot = job;
  const auto phase = phaseName();
  const bool busy = active(), isReady = ready(now), fresh = scaleFresh(now);
  const bool safe = !busy && !outputFault, rawAvailable = haveRaw;
  const long raw = rawReading;
  const bool reportSlot = busy && snapshot.phase != Phase::Taring;
  const double currentWeight = reportSlot && fresh ? itemWeight() : 0;
  const auto error = outputFault ? F("OUTPUT") : !configured ? F("CONFIG") :
      !fresh ? F("SCALE") : !busy && !emptyCup() ? F("CUP") : nullptr;
  MaterialSensors::Reading levels[SLOT_COUNT - POWDER_COUNT];
  if (configured) {
    for (size_t i = POWDER_COUNT; i < SLOT_COUNT; ++i) {
      const auto liquid = i - POWDER_COUNT;
      if (Board::slot(i).installed) levels[liquid] = MaterialSensors::liquid(liquid, now);
    }
  }

  StatusWriter out;
  out.print(F("{\"v\":1,\"event\":\"STATUS\",\"session\":"));
  out.quoted(session);
  out.print(F(",\"seq\":"));
  out.print(sequence);
  out.print(F(",\"ready\":"));
  printBool(out, isReady);
  out.print(F(",\"safe\":"));
  printBool(out, safe);
  out.print(F(",\"raw\":"));
  if (rawAvailable) out.print(raw);
  else out.print(F("null"));
  out.print(F(",\"max_total_g\":"));
  if (configured) printWeight(out, Board::MAX_TOTAL_G);
  else out.print(F("null"));
  out.print(F(",\"slots\":{"));
  if (configured) {
    bool first = true;
    for (size_t i = 0; i < SLOT_COUNT; ++i) {
      const auto &cfg = Board::slot(i);
      if (!cfg.installed) continue;
      if (!first) out.write(',');
      first = false;
      printSlot(out, i);
      out.print(F(":{\"min_g\":"));
      printWeight(out, cfg.minG);
      out.print(F(",\"max_g\":"));
      printWeight(out, cfg.maxG);
      if (i < POWDER_COUNT) {
        out.print(F(",\"present\":null,\"has_level_sensor\":false"));
      } else {
        const auto &level = levels[i - POWDER_COUNT];
        out.print(F(",\"present\":"));
        printBool(out, level.present);
        if (level.percent >= 0) {
          out.print(F(",\"remaining_pct\":"));
          out.print(static_cast<int>(level.percent));
        }
        out.print(F(",\"sensor_raw\":"));
        out.print(level.raw);
      }
      out.write('}');
    }
  }
  out.write('}');
  if (error) {
    out.print(F(",\"error_code\":"));
    out.quoted(error);
  }
  out.print(F(",\"job\":"));
  if (!snapshot.id[0]) {
    out.print(F("null}\n"));
  } else {
    out.print(F("{\"id\":"));
    out.quoted(snapshot.id);
    out.print(F(",\"phase\":"));
    out.quoted(phase);
    if (snapshot.error) {
      out.print(F(",\"error_code\":"));
      out.quoted(snapshot.error);
    }
    if (reportSlot) {
      out.print(F(",\"current_slot\":"));
      printSlot(out, snapshot.items[snapshot.index].slot);
      if (fresh) {
        out.print(F(",\"live_g\":"));
        printWeight(out, currentWeight);
      }
    }
    out.print(F(",\"items\":["));
    for (size_t i = 0; i < snapshot.count; ++i) {
      const auto &item = snapshot.items[i];
      if (i) out.write(',');
      out.print(F("{\"slot\":"));
      printSlot(out, item.slot);
      out.print(F(",\"target_g\":"));
      printWeight(out, item.targetG);
      out.print(F(",\"actual_g\":"));
      if (item.measured) printWeight(out, item.actualG);
      else out.print(F("null"));
      out.print(F(",\"done\":"));
      printBool(out, item.done);
      out.write('}');
    }
    out.print(F("]}}\n"));
  }
  lastStatusSequence = sequence;
  lastStatusAt = now;
}

bool frameSpace(char c) {
  return c == ' ' || c == '\t' || c == '\r';
}

bool singleObject(const char *line, size_t size) {
  // ArduinoJson은 첫 객체에서 파싱을 끝냅니다. 뒤에 붙은 명령이나 쓰레기 바이트를 먼저 거릅니다.
  while (size && frameSpace(*line)) { ++line; --size; }
  while (size && frameSpace(line[size - 1])) --size;
  if (!size || line[0] != '{' || line[size - 1] != '}') return false;
  size_t braces = 0;
  bool quoted = false, escaped = false;
  for (size_t i = 0; i < size; ++i) {
    const char c = line[i];
    if (c == '\0') return false;
    if (quoted) {
      if (escaped) escaped = false;
      else if (c == '\\') escaped = true;
      else if (c == '"') quoted = false;
    } else if (c == '"') quoted = true;
    else if (c == '{') ++braces;
    else if (c == '}' && --braces == 0) return i == size - 1;
  }
  return false;
}

#if defined(ARDUINO_AVR_UNO)
// 명령 파서의 작업 메모리를 loop와 상태 전송이 실행될 때까지 유지하지 않습니다.
__attribute__((noinline))
#endif
void handleFrame(char *line, size_t size, unsigned long now) {
  if (!singleObject(line, size)) return;
#if ARDUINOJSON_VERSION_MAJOR == 6
  // 문자열은 수신 버퍼에서 직접 참조하여 AVR 스택에 사본을 보관하지 않습니다.
  StaticJsonDocument<JSON_OBJECT_SIZE(7) + JSON_ARRAY_SIZE(SLOT_COUNT)
      + SLOT_COUNT * JSON_OBJECT_SIZE(2)> packet;
#else
  JsonDocument packet;
#endif
  if (deserializeJson(packet, line, size, DeserializationOption::NestingLimit(5))
      || !packet[F("v")].is<int>() || packet[F("v")].as<int>() != 1
      || !packet[F("seq")].is<uint32_t>()) return;
  const char *sender = packet[F("session")].as<const char *>();
  const JsonVariantConst command = packet[F("command")];
  if (!isId(sender) || !command.is<const char *>()) return;
  const uint32_t sequence = packet[F("seq")].as<uint32_t>();
  const bool status = command == F("GET_STATUS");
  if (strcmp(sender, session)) {
    if (!status) return;
    if (active()) finish(Phase::Error, F("SESSION_CHANGED"));
    strcpy(session, sender);
    lastSequence = lastStatusSequence = 0;
  }
  if (sequence <= lastSequence) return;
  lastSequence = sequence;
  const auto ack = packet[F("ack")];
  const bool recentStatus = lastStatusSequence != 0 && ack.is<uint32_t>()
      && ack.as<uint32_t>() == lastStatusSequence
      && !elapsed(now, lastStatusAt, Board::WATCHDOG_MS);
  if (status) {
    // Pi가 직전 STATUS를 실제로 받았을 때만 heartbeat를 갱신합니다.
    if (recentStatus) heartbeatAt = now;
    pendingStatus = sequence;
    return;
  }
  const char *id = packet[F("job_id")].as<const char *>();
  if (!isId(id)) return;
  if (command == F("START")) {
    startJob(id, packet[F("items")].as<JsonArrayConst>(), recentStatus, now);
  } else if (command == F("STOP") && !strcmp(id, job.id)) {
    stopJob(now);
  }
}

void readUart(unsigned long now) {
  if ((inputSize || inputOverflow) && now - inputAt >= FRAME_GAP_MS) {
    inputSize = 0;
    inputOverflow = false;
  }
  for (size_t read = 0; read < 32 && deviceSerial.available(); ++read) {
    const int value = deviceSerial.read();
    inputAt = now;
    if (value == '\n') {
      if (inputSize && !inputOverflow) handleFrame(input, inputSize, now);
      inputSize = 0;
      inputOverflow = false;
    } else if (value >= 0 && inputSize < FRAME_LIMIT) {
      input[inputSize++] = static_cast<char>(value);
    } else {
      inputOverflow = true;
    }
  }
}

#if defined(ARDUINO_AVR_UNO)
// 핀과 배출기를 초기화할 때 쓰는 스택은 제어 루프가 시작되기 전에 반환합니다.
__attribute__((noinline))
#endif
void setup() {
  scaleWired = scalePinsValid();
  if (scaleWired) {
    pinMode(Board::HX_SCK, OUTPUT);
    digitalWrite(Board::HX_SCK, LOW);
    pinMode(Board::HX_DOUT, INPUT_PULLUP);
  }
  configured = configurationValid();
  if (configured) {
    if (hasPowder && !PowderMotion::begin()) outputFault = true;
#if !defined(ARDUINO_AVR_UNO)
    analogReadResolution(10);
#endif
    for (size_t i = POWDER_COUNT; i < SLOT_COUNT; ++i) {
      if (!Board::slot(i).installed) continue;
      const auto &cfg = Board::LIQUIDS[i - POWDER_COUNT];
      pinMode(cfg.levelPin, cfg.levelInput == Board::LevelInput::DigitalPullup ? INPUT_PULLUP : INPUT);
      if (!Board::configureOutput(cfg.pumpPin, !cfg.pumpOnHigh)) outputFault = true;
    }
  }
  deviceSerial.begin(Board::BAUD, SERIAL_8N1);
}

void loop() {
  serviceDevice();
  readUart(millis());
  if (pendingStatus) {
    const uint32_t sequence = pendingStatus;
    pendingStatus = 0;
    statusReply(sequence, millis());
  }
}
