# BLE 페어링과 3자 상태 동기화

이 프로젝트에서 가장 손이 많이 간 부분. "어느 폰이 어느 ESP32 의 알림을 받는가" 를
**세 곳이 각자 기억**하는 구조라, 이들이 어긋났을 때 무엇을 믿을지가 설계의 핵심이었다.

## 왜 페어링이 필요한가

ESP32 가 여러 대가 되는 순간, 서버는 "이 이벤트를 누구에게 보낼지" 를 알아야 한다.
그러려면 폰이 **자기가 어느 기기를 구독하는지** 서버에 알려줘야 하고, 사용자는 그 기기를
어떻게든 지정해야 한다.

`device_id` 를 사용자가 손으로 입력하게 할 수도 있다(실제로 폴백 UI 로 남겨뒀다).
하지만 기기 뒷면의 6자리 hex 를 읽어 타이핑하는 건 좋은 첫 경험이 아니다.
**"앱을 켜면 근처 기기가 목록에 뜨고, 누르면 끝"** 이 목표였다.

WiFi 로는 이걸 못 한다. 폰과 ESP32 가 같은 서브넷에 있어야 하고 mDNS 등이 필요하다.
BLE 광고는 페어링 이전, 네트워크 설정 이전에도 동작한다. 그래서 **BLE 는 알림 경로가 아니라
오직 "이 기기가 여기 있다" 를 알리는 발견 경로**로 쓴다.

## 프로토콜

ESP32 는 커스텀 GATT 서비스 하나를 광고한다.

| 항목 | 값 |
|---|---|
| 광고 이름 | `ESP32-<device_id>` (예: `ESP32-A1B2C3`) |
| 서비스 UUID | `f47ac10b-58cc-4372-a567-0e02b2c3d479` |
| 특성 UUID | `f47ac10b-58cc-4372-a567-0e02b2c3d480` (WRITE only) |

`device_id` 는 MAC 끝 3바이트의 대문자 hex 6자. 앱은 `^ESP32-([0-9A-F]{6})$` 로 스캔
결과를 걸러 목록을 만든다 — 이름에서 바로 `device_id` 를 읽어내므로, GATT 로 값을 읽는
왕복이 필요 없다.

페어링 자체는 극단적으로 단순하다:

1. 사용자가 목록에서 기기를 탭
2. 앱이 GATT 연결 → 특성에 **아무 값이나 WRITE**
3. ESP32 는 write 콜백에서 "페어링됨" 으로 판정
4. 앱은 서버에 `POST /devices { fcm_token, platform, device_id }`

**WRITE 의 내용은 보지 않는다.** "물리적으로 BLE 사거리 안에 있는 누군가가 이 기기를
눌렀다" 는 사실 자체가 신호다. 근접성을 인증 요소로 쓰는 셈인데, 개인용 규모에서
의도적으로 감수한 단순화다 (한계는 [architecture.md](./architecture.md) 보안 모델 참조).

## 상태를 기억하는 세 곳

| 주체 | 저장소 | 기억하는 것 |
|---|---|---|
| ESP32 | NVS (`Preferences`) | `paired` 불리언 — "누군가 나를 구독 중이다" |
| 서버 | SQLite | `device_id ↔ fcm_token` 매핑 (권위) |
| 앱 | `SharedPreferences` | 내가 구독하는 `device_id` |

이 셋은 반드시 어긋난다. 앱을 삭제하면 앱의 기억만 사라지고, ESP32 를 리셋하면 ESP32 의
기억만 사라진다. 서버는 그 사실을 즉시 알 수 없다.

**해법: 서버를 단일 진실 공급원으로 삼고, 나머지 둘은 부팅/시동 때 서버에 물어본다.**

### ESP32 — 부팅 시 대조

```cpp
void reconcilePairingWithServer() {
  const int count = queryListenerCount();   // GET /devices/count?device_id=
  const bool cached = isAlreadyPaired();    // NVS

  if (count < 0) {                    // 서버 불통 → 캐시대로
    if (!cached) startBleAdvertising();
    return;
  }
  if (count > 0) {                    // 서버: 구독자 있음
    if (!cached) savePaired();        //   NVS 동기화
    // BLE 광고 생략
  } else {                            // 서버: 구독자 없음
    if (cached) clearPaired();        //   NVS 동기화
    startBleAdvertising();
  }
}
```

세 갈래 모두 의미가 있다:

- **`count > 0`** — 이미 페어링됨. **BLE 를 아예 켜지 않는다.** 뒤에 설명할 힙 문제 때문에 중요하다.
- **`count == 0`** — 앱이 페어링을 해제했거나 삭제됐다. ESP32 가 스스로 광고를 재개한다.
  사용자가 기기를 만지지 않아도 복구된다.
- **`count < 0`** (조회 실패) — 서버가 죽었거나 WiFi 가 불안정. 이때 "페어링 안 됨" 으로
  단정하면 멀쩡히 동작 중인 기기가 매 부팅마다 BLE 를 켜게 된다. **캐시를 믿는다.**

### ESP32 — 런타임 중 감지

부팅 시 대조만으로는 부족하다. 기기는 몇 달씩 안 꺼질 수 있다.
그래서 매 이벤트 전송의 응답을 신호로 쓴다:

```cpp
if (code == 200) {
  int targets = r["targets"].as<int>();
  if (targets == 0) {                   // 리스너가 사라졌다
    if (isAlreadyPaired()) clearPaired();
    if (!bleActive) startBleAdvertising();
  }
}
```

`/ingest` 응답의 `targets` 는 실제로 푸시를 보낸 대상 수다. 이게 `0` 이면 구독자가 없다는
뜻이므로 그 자리에서 페어링을 무효화하고 광고를 재개한다. **별도의 폴링이 필요 없다** —
어차피 보내야 하는 요청의 응답에 정보가 실려 온다.

### 앱 — 재설치 복구

앱을 지웠다 깔면 `SharedPreferences` 가 비어 있다. 하지만 FCM 토큰이 살아 있다면
서버가 매핑을 알고 있다:

```dart
if (deviceId == null) {
  deviceId = await _recoverFromServer();   // GET /devices/lookup?fcm_token=
}
```

이게 `GET /devices/lookup` 이 존재하는 유일한 이유다. 성공하면 사용자는 페어링 화면을
보지도 않고 바로 홈으로 들어간다.

### 사용자가 명시적으로 끊을 때

```dart
Future<void> _unpair() async {
  try {
    await http.delete(...);       // 서버에서 먼저 제거
  } catch (e) {
    debugPrint('unpair DELETE failed (continuing): $e');
  }
  await prefs.remove(_kDeviceIdKey);   // 실패해도 로컬은 정리
}
```

**서버 먼저, 로컬 나중**이고 서버 실패를 삼킨다. 반대 순서였다면 서버 요청이 실패했을 때
사용자는 로컬에 남은 페어링 때문에 해제 버튼을 다시 눌러야 하는데, 그 화면으로 돌아갈
경로가 없다. 서버에 잔여 행이 남는 쪽이 낫다 — 다음 `/ingest` 에서 FCM 이
`UnregisteredError` 를 주면 자동으로 정리되고, 안 되더라도 `targets` 불일치로 드러난다.

### 최후 수단 — 물리 버튼

```cpp
void maybeFactoryReset() {
  pinMode(FACTORY_RESET_PIN, INPUT_PULLUP);   // GPIO 0 = BOOT 버튼
  delay(50);
  if (digitalRead(FACTORY_RESET_PIN) == LOW) clearPaired();
}
```

`setup()` 의 **맨 첫 줄**에서, WiFi 연결보다 먼저 실행한다. WiFi 가 안 붙는 상황에서도
동작해야 의미가 있기 때문이다. BOOT 버튼을 누른 채 리셋하면 NVS 플래그가 지워진다.

## 힙 — BLE 와 TLS 는 사이가 나쁘다

ESP32 에서 BLE 스택과 TLS 핸드셰이크는 **둘 다 힙을 크게 먹는다.** 동시에 살려두면
`WiFiClientSecure` 가 핸드셰이크 중 메모리 부족으로 실패한다. 증상이 고약한 게, 연결이
"가끔" 실패하고 재부팅하면 잠깐 되기도 한다.

대응은 두 가지다.

**1. 페어링이 끝나면 BLE 를 완전히 반환한다.**

```cpp
BLEDevice::getAdvertising()->stop();
BLEDevice::deinit(true);      // true = 힙 반환
```

`stop()` 만으로는 스택이 메모리를 쥐고 있다. `deinit(true)` 여야 실제로 돌아온다.

**2. 이미 페어링됐으면 BLE 를 아예 켜지 않는다.**

부팅 시 대조에서 `count > 0` 이면 `startBleAdvertising()` 자체를 건너뛴다.
정상 운영 중인 기기는 BLE 스택을 한 번도 초기화하지 않는다.

페어링 신호를 받은 직후에는 잠깐 기다린다:

```cpp
if (pairSignalReceived) {
  delay(300);        // 앱의 disconnect 완료 대기
  savePaired();
}
```

WRITE 콜백이 뜬 즉시 `deinit` 하면 앱 쪽에서 GATT 연결이 끊기며 오류로 처리되는 경우가
있었다. 300ms 는 실측으로 정한 값이다.

광고에는 **5분 폴백 타임아웃**을 뒀다. 앱이 GATT WRITE 를 못 하고 이탈하는 경우에도
BLE 가 영원히 켜져 있지 않도록 한다.

## 빌드 제약 — 파티션

BLE + WiFi + TLS 를 한 바이너리에 넣으면 **약 1.79MB** 가 된다.
ESP32 기본 파티션의 앱 영역은 1.31MB 라 **들어가지 않는다**:

```
Sketch uses 1786123 bytes (136%) of program storage space. Maximum is 1310720 bytes.
Error during build: text section exceeds available space in board
```

`Huge APP (3MB No OTA)` 파티션으로 바꾸면 3.15MB 중 56% 로 여유가 생긴다.
OTA 를 포기하는 대신 얻는 공간인데, 이 프로젝트는 어차피 USB 로 플래시하므로 문제없다.

```bash
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app esp32-firmware/PushRelay
```

classic ESP32 는 1.79MB(56%), ESP32-C3 는 1.35MB(42%) 로 둘 다 들어간다.

## 전체 상태 흐름

```
                     ┌──────────────────┐
     BOOT 버튼 누름 ─▶│  NVS: unpaired   │◀─ /ingest 응답 targets == 0
                     └────────┬─────────┘
                              │ 부팅: GET /devices/count → 0
                              ▼
                     ┌──────────────────┐
                     │  BLE 광고 중      │──── 5분 경과 ────▶ 광고 중단 (미페어링 유지)
                     └────────┬─────────┘
                              │ 앱이 GATT WRITE
                              ▼
                     ┌──────────────────┐
                     │ savePaired()     │
                     │ BLE deinit(true) │
                     └────────┬─────────┘
                              │ 앱이 POST /devices
                              ▼
                     ┌──────────────────┐
                     │  NVS: paired     │
                     │  서버: 매핑 존재  │◀─ 부팅: GET /devices/count → N>0 (BLE 생략)
                     └──────────────────┘
```
