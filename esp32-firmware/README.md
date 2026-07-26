# esp32-firmware

WiFi 로 연결해 서버의 `/ingest` 에 HTTPS POST 를 보내는 ESP32 펌웨어.
BLE 로 앱과 페어링하고, 서버를 진실 공급원 삼아 페어링 상태를 동기화한다.

정본 스케치: **`PushRelay/PushRelay.ino`** (Arduino IDE).

## 빌드 전 설정 — `secrets.h`

WiFi 자격증명·API 키·**서버 주소** 는 소스에 박지 않는다. `secrets.h` 는 `.gitignore` 로 제외된다.

```bash
cp secrets.h.example PushRelay/secrets.h
$EDITOR PushRelay/secrets.h
```

| 심볼 | 내용 |
|---|---|
| `WIFI_SSID` / `WIFI_PASS` | 접속할 AP |
| `API_KEY` | 서버 `.env` 의 `API_KEY` 와 동일해야 함 (`grep ^API_KEY= api-server/.env`) |
| `PUSH_BASE_URL` | 서버 베이스 URL, **끝 슬래시 없이** (예: `"https://<push-host>"`) |

`PUSH_BASE_URL` 만 `#define` 인 이유: `PUSH_BASE_URL "/ingest"` 처럼 **컴파일 타임 문자열 리터럴 연결**로
엔드포인트를 만들기 때문. 런타임 비용이 없고 기존 `const char*` 사용부를 그대로 둘 수 있다.

서버 도메인을 교체할 때는 이 한 줄만 바꾸고 재플래시하면 된다.

## 빌드 / 업로드

> ⚠ **파티션 스킴을 반드시 바꿔야 한다.** BLE + WiFi + TLS 를 함께 쓰면 바이너리가 약 1.79 MB 라
> 기본 스킴(앱 영역 1.31 MB)에 **들어가지 않는다** — `text section exceeds available space in board` 로 실패.
> Arduino IDE: `Tools → Partition Scheme → Huge APP (3MB No OTA/1MB SPIFFS)` (3.15 MB 중 56% 사용).

**Arduino IDE**: `PushRelay/PushRelay.ino` 열기 → 보드 선택 → 위 파티션 스킴 지정 → 업로드.
필요 라이브러리: `ArduinoJson` (7.x). WiFi·HTTPClient·BLE·Preferences 는 ESP32 코어 내장.

**arduino-cli**:

```bash
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app PushRelay
arduino-cli upload  --fqbn esp32:esp32:esp32:PartitionScheme=huge_app -p <COM포트> PushRelay
```

보드는 classic ESP32 / ESP32-C3 양쪽 다 빌드된다 (각각 1.79MB·56%, 1.35MB·42%).
C3 를 쓴다면 `--fqbn esp32:esp32:esp32c3:PartitionScheme=huge_app`.

> PlatformIO 는 쓰지 않는다. 과거 `src/main.cpp` + `platformio.ini` 스텁이 있었으나
> 서버 API 계약(`device_id` 필수)을 만족하지 못하는 死코드여서 제거했다.

## 동작 개요

1. 부팅 시 BOOT 버튼(GPIO 0)이 눌려 있으면 NVS 의 페어링 플래그를 지운다 (팩토리 리셋).
2. WiFi 연결 → MAC 끝 3바이트로 `device_id` 산출 (예: `A1B2C3`).
3. `GET /devices/count?device_id=<id>` 로 **서버에 등록된 리스너 수**를 조회해 NVS 캐시와 동기화.
   - `count > 0` → 페어링됨. BLE 광고 생략 (힙 절약).
   - `count == 0` → BLE 광고 시작. 앱이 GATT write 를 보내면 페어링 확정 후 광고 중단.
   - 조회 실패 → NVS 캐시대로 동작.
4. `POST /ingest` 로 이벤트 전송. 응답의 `targets == 0` 이면 리스너가 사라진 것으로 보고 BLE 재활성.

BLE 는 페어링이 끝나면 `BLEDevice::deinit(true)` 로 힙을 반환한다 — TLS 핸드셰이크에 힙이 필요하기 때문.

## TLS

`TLS_INSECURE = false` (기본) 이면 Let's Encrypt **ISRG Root X1** 을 바이너리에 고정해 검증한다.
`true` 는 개발 편의용이며 프로덕션에서 쓰지 말 것.

> 루트 CA 는 2035-06-04 만료. 그 전에 Let's Encrypt 가 체인을 바꾸면 PEM 교체 필요.
