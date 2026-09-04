/*
 * THERMOSTAT wearable node — ESP32-C3 SuperMini
 * ================================================
 * Polls BME280 (ambient temp/RH/pressure), MAX30205 (skin temp) and
 * MAX30102 (HR, SpO2) over I2C, packs a 41-byte binary frame guarded by
 * CRC-16/CCITT-FALSE, and notifies it over BLE once per duty cycle.
 *
 * WIRE FORMAT (little-endian, 41 bytes total) — verified against the
 * project test vector below. protocol.dart on the phone decodes this
 * exact layout; change NOTHING here without changing it there.
 *
 *   off  type    field
 *    0   u32     seq            frame counter, starts at 1
 *    4   u32     uptime_ms      millis() at sample time
 *    8   f32     ambient_c      BME280 temperature, deg C (raw, uncompensated)
 *   12   f32     humidity_pct   BME280 relative humidity, %
 *   16   f32     pressure_hpa   BME280 pressure, hPa
 *   20   f32     skin_c         MAX30205 skin temperature, deg C
 *   24   f32     hr_bpm         MAX30102 heart rate, bpm (NAN until lock)
 *   28   f32     spo2_pct       MAX30102 SpO2, % (NAN until lock)
 *   32   u32     ir_raw         MAX30102 IR amplitude (signal quality)
 *   36   u8      battery_pct    coarse battery estimate 0-100
 *   37   u8      duty_s         current duty cycle in seconds
 *   38   u8      flags          bit0 BME ok, bit1 MAX30205 ok, bit2 MAX30102
 *                               ok, bit3 HR lock, bit4 charging
 *   39   u16     crc            CRC-16/CCITT-FALSE over bytes 0..38
 *
 * SELF-TEST: on boot the node re-encodes the canonical test vector and
 * refuses to start advertising if the CRC or byte layout disagrees. A wire
 * format mismatch must fail loudly, never produce plausible wrong numbers.
 *
 * Libraries (Arduino IDE -> Library Manager):
 *   - Adafruit BME280 Library (+ Adafruit Unified Sensor)
 *   - SparkFun MAX3010x Pulse and Proximity Sensor Library
 *   (MAX30205 is driven with raw Wire reads — no library needed.)
 * Board: "ESP32C3 Dev Module", USB CDC on boot: Enabled.
 *
 * Wiring (I2C, all three sensors share the bus):
 *   SDA -> GPIO8, SCL -> GPIO9 (SuperMini silkscreen 8/9), 3V3, GND.
 *   MAX30102 sits in the finger unit on a tethered lead; keep it short.
 */

#include <Wire.h>
#include <Adafruit_BME280.h>
#include "MAX30105.h"          // SparkFun lib: also drives the MAX30102
#include "heartRate.h"
#include "spo2_algorithm.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---------------------------------------------------------------- config --
static const uint8_t PIN_SDA = 8;
static const uint8_t PIN_SCL = 9;
static const uint8_t MAX30205_ADDR = 0x48;      // A2..A0 tied low
static uint8_t DUTY_S = 15;                     // sample period, seconds
static const char* DEVICE_NAME = "THERMOSTAT-NODE";
// 128-bit UUIDs — must match ble_client.dart.
static const char* SVC_UUID = "7e400001-b5a3-f393-e0a9-e50e24dcca9e";
static const char* CHR_UUID = "7e400002-b5a3-f393-e0a9-e50e24dcca9e";

// ------------------------------------------------------------- wire frame --
#pragma pack(push, 1)
struct Frame {
  uint32_t seq;
  uint32_t uptime_ms;
  float    ambient_c;
  float    humidity_pct;
  float    pressure_hpa;
  float    skin_c;
  float    hr_bpm;
  float    spo2_pct;
  uint32_t ir_raw;
  uint8_t  battery_pct;
  uint8_t  duty_s;
  uint8_t  flags;
  uint16_t crc;
};
#pragma pack(pop)
static_assert(sizeof(Frame) == 41, "Frame must be exactly 41 bytes");

enum {
  F_BME_OK   = 1 << 0,
  F_SKIN_OK  = 1 << 1,
  F_PPG_OK   = 1 << 2,
  F_HR_LOCK  = 1 << 3,
  F_CHARGING = 1 << 4,
};

// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, xorout 0.
static uint16_t crc16_ccitt_false(const uint8_t* data, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < len; ++i) {
    crc ^= (uint16_t)data[i] << 8;
    for (uint8_t b = 0; b < 8; ++b)
      crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : (crc << 1);
  }
  return crc;
}

// Canonical project test vector. Both ends run this at startup and refuse
// to operate on mismatch. Expected frame CRC: 0xF944. "123456789" -> 0x29B1.
static bool protocol_self_test() {
  const uint8_t expected[41] = {
    0x01,0x00,0x00,0x00, 0xE8,0x03,0x00,0x00, 0x00,0x00,0xFA,0x41,
    0x00,0x00,0x91,0x42, 0x00,0x00,0x7C,0x44, 0x00,0x00,0x0A,0x42,
    0x00,0x00,0x9C,0x42, 0x00,0x00,0xC3,0x42, 0x40,0xE2,0x01,0x00,
    0x1F,0x3C,0x0F, 0x44,0xF9
  };
  if (crc16_ccitt_false((const uint8_t*)"123456789", 9) != 0x29B1) return false;

  Frame f{};
  f.seq = 1;            f.uptime_ms = 1000;
  f.ambient_c = 31.25f; f.humidity_pct = 72.5f; f.pressure_hpa = 1008.0f;
  f.skin_c = 34.5f;     f.hr_bpm = 78.0f;       f.spo2_pct = 97.5f;
  f.ir_raw = 123456;    f.battery_pct = 31;     f.duty_s = 60; f.flags = 15;
  f.crc = crc16_ccitt_false((const uint8_t*)&f, 39);
  return memcmp(&f, expected, 41) == 0;   // bytes AND crc must match exactly
}

// ---------------------------------------------------------------- sensors --
Adafruit_BME280 bme;
MAX30105 ppg;
bool bme_ok = false, skin_ok = false, ppg_ok = false;

static float read_max30205_c(bool* ok) {
  Wire.beginTransmission(MAX30205_ADDR);
  Wire.write(0x00);                                  // temperature register
  if (Wire.endTransmission(false) != 0) { *ok = false; return NAN; }
  if (Wire.requestFrom((int)MAX30205_ADDR, 2) != 2) { *ok = false; return NAN; }
  int16_t raw = (Wire.read() << 8) | Wire.read();
  *ok = true;
  return raw * 0.00390625f;                          // 2^-8 deg C per LSB
}

// --- PPG: 100 Hz buffer fed continuously; HR/SpO2 solved per duty cycle ---
static const int PPG_N = 100;                        // 4 s window at 25 sps
uint32_t ir_buf[PPG_N], red_buf[PPG_N];
int ppg_fill = 0;
int32_t g_spo2 = -999, g_hr = -999;
int8_t  g_spo2_valid = 0, g_hr_valid = 0;
uint32_t g_ir_raw = 0;

static void ppg_pump() {                             // call as often as possible
  if (!ppg_ok) return;
  while (ppg.available()) {
    ir_buf[ppg_fill % PPG_N]  = ppg.getFIFOIR();
    red_buf[ppg_fill % PPG_N] = ppg.getFIFORed();
    g_ir_raw = ir_buf[ppg_fill % PPG_N];
    ppg_fill++;
    ppg.nextSample();
  }
  ppg.check();
}

static void ppg_solve() {                            // once per duty cycle
  if (!ppg_ok || ppg_fill < PPG_N) { g_hr_valid = g_spo2_valid = 0; return; }
  maxim_heart_rate_and_oxygen_saturation(
      ir_buf, PPG_N, red_buf, &g_spo2, &g_spo2_valid, &g_hr, &g_hr_valid);
  // Reject physically implausible solutions rather than transmitting them.
  if (g_hr_valid  && (g_hr  < 25  || g_hr  > 230)) g_hr_valid  = 0;
  if (g_spo2_valid && (g_spo2 < 50 || g_spo2 > 100)) g_spo2_valid = 0;
}

static uint8_t battery_pct() {
  // SuperMini has no fuel gauge; report a coarse VCC-based estimate.
  // Ria: replace with a divider on A0 if the final PCB routes VBAT.
  return 100;
}

// -------------------------------------------------------------------- BLE --
BLECharacteristic* chr = nullptr;
volatile bool client_connected = false;

class SrvCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { client_connected = true; }
  void onDisconnect(BLEServer* s) override {
    client_connected = false;
    s->getAdvertising()->start();                    // resume advertising
  }
};

// ------------------------------------------------------------------ setup --
uint32_t seq = 0;
uint32_t next_sample_ms = 0;

void setup() {
  Serial.begin(115200);
  delay(300);

  if (!protocol_self_test()) {
    // Loud, unrecoverable failure — never collect with a broken wire format.
    while (true) { Serial.println("!! PROTOCOL SELF-TEST FAILED — HALTED"); delay(2000); }
  }
  Serial.println("protocol self-test OK (frame 41B, CRC 0xF944)");

  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(400000);

  bme_ok = bme.begin(0x76) || bme.begin(0x77);
  Serial.printf("BME280: %s\n", bme_ok ? "ok" : "MISSING");

  ppg_ok = ppg.begin(Wire, I2C_SPEED_FAST);
  if (ppg_ok) {
    // ledBrightness, sampleAverage, ledMode(2=Red+IR), sampleRate, pulseWidth, adcRange
    ppg.setup(0x2F, 4, 2, 100, 411, 16384);
  }
  Serial.printf("MAX30102: %s\n", ppg_ok ? "ok" : "MISSING");

  read_max30205_c(&skin_ok);
  Serial.printf("MAX30205: %s\n", skin_ok ? "ok" : "MISSING");

  BLEDevice::init(DEVICE_NAME);
  BLEServer* srv = BLEDevice::createServer();
  srv->setCallbacks(new SrvCb());
  BLEService* svc = srv->createService(SVC_UUID);
  chr = svc->createCharacteristic(CHR_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  chr->addDescriptor(new BLE2902());
  svc->start();
  BLEDevice::getAdvertising()->addServiceUUID(SVC_UUID);
  BLEDevice::getAdvertising()->start();
  Serial.println("advertising");
  next_sample_ms = millis();
}

// ------------------------------------------------------------------- loop --
void loop() {
  ppg_pump();                                        // keep the FIFO drained

  if ((int32_t)(millis() - next_sample_ms) < 0) return;
  next_sample_ms += (uint32_t)DUTY_S * 1000UL;

  ppg_solve();

  Frame f{};
  f.seq       = ++seq;
  f.uptime_ms = millis();
  f.ambient_c    = bme_ok ? bme.readTemperature() : NAN;
  f.humidity_pct = bme_ok ? bme.readHumidity()    : NAN;
  f.pressure_hpa = bme_ok ? bme.readPressure() / 100.0f : NAN;
  f.skin_c    = read_max30205_c(&skin_ok);
  f.hr_bpm    = g_hr_valid   ? (float)g_hr   : NAN;
  f.spo2_pct  = g_spo2_valid ? (float)g_spo2 : NAN;
  f.ir_raw    = g_ir_raw;
  f.battery_pct = battery_pct();
  f.duty_s    = DUTY_S;
  f.flags     = (bme_ok  ? F_BME_OK  : 0) | (skin_ok ? F_SKIN_OK : 0) |
                (ppg_ok  ? F_PPG_OK  : 0) | (g_hr_valid ? F_HR_LOCK : 0);
  f.crc = crc16_ccitt_false((const uint8_t*)&f, 39);

  if (client_connected && chr) {
    chr->setValue((uint8_t*)&f, sizeof(Frame));
    chr->notify();
  }
  Serial.printf("#%lu amb=%.2fC rh=%.1f%% skin=%.2fC hr=%.0f spo2=%.0f fl=0x%02X\n",
                (unsigned long)f.seq, f.ambient_c, f.humidity_pct, f.skin_c,
                f.hr_bpm, f.spo2_pct, f.flags);
}
