#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLEAdvertising.h>
#include <BLE2902.h>
#include <Preferences.h>

#include "secrets.h"

// Custom pairing service (앱이 이 UUID 로 필터링하고 WRITE 전송)
#define PAIR_SERVICE_UUID "f47ac10b-58cc-4372-a567-0e02b2c3d479"
#define PAIR_CHAR_UUID    "f47ac10b-58cc-4372-a567-0e02b2c3d480"

// 영구 페어링 상태 저장 (NVS)
static const char* NVS_NAMESPACE   = "pushrelay";
static const char* NVS_KEY_PAIRED  = "paired";
static const int FACTORY_RESET_PIN = 0;  // GPIO 0 = BOOT 버튼

bool isAlreadyPaired() {
  Preferences p;
  p.begin(NVS_NAMESPACE, true);  // read-only
  bool v = p.getBool(NVS_KEY_PAIRED, false);
  p.end();
  return v;
}

void savePaired() {
  Preferences p;
  p.begin(NVS_NAMESPACE, false);
  p.putBool(NVS_KEY_PAIRED, true);
  p.end();
}

void clearPaired() {
  Preferences p;
  p.begin(NVS_NAMESPACE, false);
  p.remove(NVS_KEY_PAIRED);
  p.end();
}

void maybeFactoryReset() {
  pinMode(FACTORY_RESET_PIN, INPUT_PULLUP);
  delay(50);  // 디바운스
  if (digitalRead(FACTORY_RESET_PIN) == LOW) {
    Serial.println("[reset] BOOT button held — clearing paired flag");
    clearPaired();
  }
}

// PUSH_BASE_URL 은 secrets.h 의 매크로 (예: "https://<push-host>"). secrets.h 는 git 밖.
// 문자열 리터럴 연결이므로 런타임 비용 0 — 기존 const char* 사용부를 그대로 유지한다.
static const char* INGEST_URL     = PUSH_BASE_URL "/ingest";
static const char* COUNT_URL_BASE = PUSH_BASE_URL "/devices/count?device_id=";

// true: 인증서 검증 생략 (개발용). false: ISRG Root X1 고정 (프로덕션용)
static const bool TLS_INSECURE = false;

static const char* LETSENCRYPT_ROOT_X1 = R"(-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----)";

String deviceId;  // MAC 끝 6자리 대문자 hex — 페어링 식별자

void computeDeviceId() {
  uint8_t mac[6];
  WiFi.macAddress(mac);
  char buf[7];
  snprintf(buf, sizeof(buf), "%02X%02X%02X", mac[3], mac[4], mac[5]);
  deviceId = String(buf);
  Serial.printf("[id] Device ID: %s  (full MAC: %02X:%02X:%02X:%02X:%02X:%02X)\n",
                deviceId.c_str(), mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static uint32_t bleStartedAt = 0;
static bool bleActive = false;
static volatile bool pairSignalReceived = false;
// 폴백 타임아웃: 앱이 GATT write 를 못 하는 경우에도 이 시간 지나면 BLE 중단
static const uint32_t BLE_ADVERTISE_MS = 5UL * 60UL * 1000UL;  // 5 분

class PairCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* chr) override {
    pairSignalReceived = true;
    Serial.println("[ble] pair signal received");
  }
};

void startBleAdvertising() {
  String bleName = "ESP32-" + deviceId;
  BLEDevice::init(bleName.c_str());
  BLEServer* server = BLEDevice::createServer();
  BLEService* service = server->createService(PAIR_SERVICE_UUID);
  BLECharacteristic* chr = service->createCharacteristic(
      PAIR_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
  chr->setCallbacks(new PairCallback());
  service->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(PAIR_SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
  bleStartedAt = millis();
  bleActive = true;
  pairSignalReceived = false;
  Serial.printf("[ble] advertising as: %s  (%lu 초 폴백 타임아웃, free heap=%u)\n",
                bleName.c_str(), BLE_ADVERTISE_MS / 1000, ESP.getFreeHeap());
}

void maybeStopBle() {
  if (!bleActive) return;
  const bool timedOut = (millis() - bleStartedAt) >= BLE_ADVERTISE_MS;
  if (!pairSignalReceived && !timedOut) return;

  // pair 신호 직후엔 앱의 disconnect 완료까지 잠깐 대기 + NVS 저장
  if (pairSignalReceived) {
    delay(300);
    savePaired();
    Serial.println("[pair] saved to NVS");
  }

  BLEDevice::getAdvertising()->stop();
  BLEDevice::deinit(true);   // 힙 반환 (TLS 에게 양보)
  bleActive = false;
  Serial.printf("[ble] stopped (%s, free heap=%u)\n",
                pairSignalReceived ? "paired" : "timeout",
                ESP.getFreeHeap());
}

void connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("[wifi] connecting");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.printf("\n[wifi] ok, ip=%s\n", WiFi.localIP().toString().c_str());
}

// 서버에 내 device_id 로 등록된 리스너 수 조회.
// 반환: >=0 (성공), -1 (네트워크/파싱 오류 → 캐시로 폴백)
int queryListenerCount() {
  if (WiFi.status() != WL_CONNECTED) connectWifi();
  WiFiClientSecure client;
  if (TLS_INSECURE) client.setInsecure();
  else              client.setCACert(LETSENCRYPT_ROOT_X1);

  String url = String(COUNT_URL_BASE) + deviceId;
  HTTPClient http;
  if (!http.begin(client, url)) return -1;
  http.setTimeout(10000);

  int code = http.GET();
  int count = -1;
  if (code == 200) {
    String body = http.getString();
    JsonDocument doc;
    if (deserializeJson(doc, body) == DeserializationError::Ok) {
      count = doc["count"].as<int>();
    }
  }
  Serial.printf("[pair] GET count -> code=%d count=%d\n", code, count);
  http.end();
  return count;
}

// 서버를 진실 공급원으로 삼아 NVS 상태와 일치시킴.
// 결과에 따라 BLE 광고를 시작하거나 생략한다.
void reconcilePairingWithServer() {
  const int count = queryListenerCount();
  const bool cached = isAlreadyPaired();

  if (count < 0) {
    // 서버 조회 실패 → 캐시대로 동작
    if (cached) {
      Serial.printf("[pair] server unreachable, using cache=paired (free heap=%u)\n",
                    ESP.getFreeHeap());
    } else {
      Serial.println("[pair] server unreachable, using cache=unpaired — starting BLE");
      startBleAdvertising();
    }
    return;
  }

  if (count > 0) {
    if (!cached) {
      savePaired();
      Serial.println("[pair] NVS synced: paired");
    }
    Serial.printf("[pair] server confirms paired (count=%d), skipping BLE\n", count);
  } else {
    if (cached) {
      clearPaired();
      Serial.println("[pair] NVS synced: unpaired (server has 0 listeners)");
    }
    Serial.println("[pair] server says unpaired — starting BLE");
    startBleAdvertising();
  }
}

int postIngest(const char* title, const char* body) {
  if (WiFi.status() != WL_CONNECTED) connectWifi();

  WiFiClientSecure client;
  if (TLS_INSECURE) {
    client.setInsecure();
  } else {
    client.setCACert(LETSENCRYPT_ROOT_X1);
  }

  HTTPClient http;
  if (!http.begin(client, INGEST_URL)) {
    Serial.println("[http] begin failed");
    return -1;
  }
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-API-Key", API_KEY);
  http.setTimeout(10000);

  JsonDocument doc;
  doc["title"]     = title;
  doc["body"]      = body;
  doc["device_id"] = deviceId;
  String payload;
  serializeJson(doc, payload);

  Serial.printf("[http] free heap before POST=%u\n", ESP.getFreeHeap());
  int code = http.POST(payload);
  Serial.printf("[http] POST %s -> %d\n", INGEST_URL, code);

  if (code == 200) {
    String respBody = http.getString();
    Serial.printf("[http] body: %s\n", respBody.c_str());
    JsonDocument r;
    if (deserializeJson(r, respBody) == DeserializationError::Ok) {
      int targets = r["targets"].as<int>();
      if (targets == 0) {
        Serial.println("[pair] targets=0 → listener 사라짐, BLE 재활성");
        if (isAlreadyPaired()) clearPaired();
        if (!bleActive) startBleAdvertising();
      }
    }
  } else if (code > 0) {
    Serial.printf("[http] body: %s\n", http.getString().c_str());
  }
  http.end();
  return code;
}

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n[boot] ESP32 Push Relay firmware");
  maybeFactoryReset();     // 가장 먼저 — BOOT 버튼 눌림 확인
  connectWifi();           // WiFi 연결 후에 MAC 이 유효해짐
  computeDeviceId();

  reconcilePairingWithServer();   // 서버 상태를 진실 공급원으로 동기화
}

void loop() {
  maybeStopBle();
  static uint32_t last = 0;
  uint32_t now = millis();
  if (now - last > 60000UL) {
    last = now;
    postIngest("ESP32 test", "벨이 울렸습니다요. ");
  }
  delay(100);
}
