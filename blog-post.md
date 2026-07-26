---
title: "ESP32 이벤트를 스마트폰 푸시로 — 개인 IoT 릴레이를 만들며 배운 것들"
description: "ESP32 → 자체 VPS → FCM → Flutter 앱. BLE 페어링과 3자 상태 동기화, 그리고 임베디드에서 힙과 플래시가 실제로 벽이 되는 지점에 대한 기록."
pubDate: 2026-07-26
tags: ["ESP32", "FCM", "FastAPI", "Flutter", "BLE", "IoT"]
draft: false
---

집에 센서를 하나 달아두고, 뭔가 감지되면 **밖에 있어도 폰에 알림이 뜨게** 하고 싶었다.
요구사항은 두 줄이면 끝난다.

- 집 밖에서도 받는다.
- 앱이 꺼져 있어도 받는다.

이 두 줄이 생각보다 많은 것을 강제했다. 만들면서 몇 번 방향을 틀었고, 그 틀었던 지점들이
이 글의 내용이다. 코드는 [저장소](https://github.com/yeyebee/esp32-push-relay-showcase)에
있고, 이 글이 인용하는 시점은 `v1.1-blog` 태그로 고정해뒀다.

---

## 1. 왜 중계 서버가 끼어드는가

"앱이 꺼져 있어도" 라는 조건이 사실상 FCM(Firebase Cloud Messaging)을 확정한다.
OS 레벨에서 알림을 띄우려면 플랫폼 푸시 인프라를 타야 하고, Android/iOS 를 한 번에 덮으려면
FCM 이 가장 현실적이다.

그런데 FCM 으로 푸시를 **보내려면** 서버 측 자격증명이 필요하다. Firebase 서비스 계정 키
JSON 인데, 이건 프로젝트 전체에 대한 관리자 권한이다.

이걸 ESP32 펌웨어에 넣을 수는 없다. 플래시는 덤프할 수 있고, 한 번 새어나가면 Firebase
프로젝트가 통째로 뚫린다. 기기를 회수할 수도 없다.

그래서 비밀을 두 등급으로 나눴다.

| | 어디에 | 유출되면 |
|---|---|---|
| **강한 비밀** — Firebase 서비스 계정 키 | 서버 디스크만, `chmod 600` | 프로젝트 전체 장악 |
| **약한 비밀** — API 키 | 펌웨어 + 서버 `.env` | 그 API 만 남용. 재발급으로 끝 |

ESP32 는 약한 비밀만 들고 서버를 부른다. 서버가 강한 비밀로 FCM 을 호출한다.
**중계 서버는 편의가 아니라 자격증명 격리를 위해 존재한다.** 이게 이 프로젝트의 첫 결정이었다.

```
ESP32 ──(약한 비밀)──▶ 내 서버 ──(강한 비밀)──▶ FCM ──▶ 폰
```

### MQTT 를 안 쓴 이유

ESP32 예제는 대개 MQTT 를 쓴다. 여기서는 HTTPS REST 를 골랐다.

트래픽이 **이벤트가 날 때만** 흐른다. 상시 연결을 유지할 이유가 없다. MQTT 를 얹으면
브로커 프로세스 + 포트 + 브로커 인증이 늘어나는데, 1GB VPS 에서 구성 요소를 하나 더
늘리는 비용이 이득보다 컸다. 서버 → ESP32 방향 명령도 필요 없었다.

단방향이고 간헐적이면 REST 로 충분하다. 양방향 제어가 필요해지면 그때 MQTT 를 얹는 게 맞다.

---

## 2. 첫 버전이 틀린 지점 — 브로드캐스트

처음 서버는 이렇게 동작했다. `/ingest` 로 이벤트가 오면 **등록된 모든 FCM 토큰에** 푸시를
보낸다. 기기가 한 대일 때는 완벽하게 잘 됐다.

두 대가 되는 순간 무너진다. 거실 센서가 울렸는데 현관 알림도 같이 뜨고, 남의 기기에
페어링한 사람에게도 내 알림이 간다. "모든 토큰" 이라는 대상 정의 자체가 틀렸던 것이다.

그래서 `device_id` 를 도입했다. **ESP32 의 MAC 주소 끝 3바이트를 대문자 hex 6자로** 쓴다
(예: `A1B2C3`). 공장에서 부여되는 값이라 별도 프로비저닝 없이 유일하고, 뒤에 나올 BLE
광고 이름에도 그대로 재사용된다.

스키마는 이렇게 됐다.

```sql
CREATE TABLE devices (
    fcm_token   TEXT PRIMARY KEY,   -- 폰 하나 = 행 하나
    platform    TEXT NOT NULL CHECK(platform IN ('android','ios')),
    device_id   TEXT,               -- 이 폰이 구독하는 ESP32
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
```

`fcm_token` 이 PK 다. FCM 토큰은 "폰 + 앱 설치 인스턴스" 를 유일하게 가리키므로,
같은 폰이라도 앱을 재설치하면 새 행이 된다.

`device_id` 가 `NOT NULL` 이 아닌 건 마이그레이션의 흉터다. 이미 돌아가는 서버의 DB 에
컬럼을 추가해야 했다:

```python
cols = [r[1] for r in conn.execute("PRAGMA table_info(devices)").fetchall()]
if "device_id" not in cols:
    conn.execute("ALTER TABLE devices ADD COLUMN device_id TEXT")
```

Alembic 을 붙일 규모가 아니라 앱 시동 시 스키마를 스스로 맞추게 했다.
`CREATE TABLE IF NOT EXISTS` + 조건부 `ALTER TABLE`. 지금도 이 정도면 충분하다고 생각한다.

### 필수 필드가 나중에 진단 도구가 됐다

`/ingest` 의 `device_id` 를 **기본값 없는 필수 필드**로 만들었다.

```python
class IngestPayload(BaseModel):
    title: str
    body: str
    device_id: str = Field(min_length=1, max_length=64)
```

한참 뒤, 저장소에 펌웨어가 두 갈래로 남아 있는 걸 발견했다. 어느 쪽이 실제로 돌아가는
코드인지 기억이 안 났다. 커밋 로그도 도움이 안 됐다.

서버에 물어보니 1초 만에 끝났다.

```
$ curl -X POST https://<push-host>/ingest -H "X-API-Key: $KEY" \
    -d '{"title":"probe","body":"probe"}'

{"detail":[{"type":"missing","loc":["body","device_id"],"msg":"Field required"}]}
```

422. 구버전 펌웨어가 보내는 형태 그대로 재현했더니 서버가 거절했다. 그 펌웨어는 현재
서버 상대로 **단 한 번도 성공할 수 없는** 코드였다. 死코드 판정 끝.

필수 필드로 만든 건 그냥 계약을 엄격하게 하려던 것이었는데, 결과적으로 **"이 클라이언트가
현재 서버와 호환되는가" 를 한 줄로 검증하는 도구**가 됐다. 느슨한 스키마(`device_id`
없으면 기본값)였다면 구버전이 조용히 이상한 동작을 하며 살아남았을 것이다.

---

## 3. 페어링 — BLE 를 알림 경로가 아니라 발견 경로로

기기가 여럿이면 사용자가 "어느 기기를 구독할지" 를 골라야 한다.

`device_id` 를 손으로 입력하게 할 수도 있다. 실제로 폴백 UI 로 남겨뒀다. 하지만 기기
뒷면의 6자리 hex 를 읽어 타이핑하는 건 좋은 첫 경험이 아니다. **앱을 켜면 근처 기기가
목록에 뜨고, 누르면 끝**이었으면 했다.

WiFi 로는 어렵다. 폰과 ESP32 가 같은 서브넷에 있어야 하고 mDNS 같은 게 필요하다.
BLE 광고는 네트워크 설정 이전, 페어링 이전에도 그냥 된다.

그래서 BLE 를 **알림 경로가 아니라 오직 발견 경로로만** 썼다. 알림은 전부 FCM 을 탄다.
BLE 는 "이 기기가 여기 있다" 를 알리는 데만 쓰인다.

ESP32 는 커스텀 GATT 서비스 하나를 광고한다.

| 항목 | 값 |
|---|---|
| 광고 이름 | `ESP32-<device_id>` (예: `ESP32-A1B2C3`) |
| 서비스 UUID | `f47ac10b-58cc-4372-a567-0e02b2c3d479` |
| 특성 | `...d480`, WRITE only |

앱은 `^ESP32-([0-9A-F]{6})$` 로 스캔 결과를 거른다. **이름에서 바로 `device_id` 를 읽어내므로
GATT 로 값을 읽어오는 왕복이 없다.** 스캔 결과가 곧 목록이다.

페어링 자체는 민망할 만큼 단순하다.

1. 사용자가 목록에서 탭
2. 앱이 GATT 연결 → 특성에 **아무 값이나** WRITE
3. ESP32 는 write 콜백이 불린 것만으로 "페어링됨" 판정
4. 앱이 서버에 `POST /devices { fcm_token, platform, device_id }`

WRITE 의 내용은 읽지도 않는다. **"BLE 사거리 안에 있는 누군가가 이 기기를 눌렀다"** 는
사실 자체가 신호다. 근접성을 인증 요소로 쓰는 셈인데, 이건 뒤에서 다시 얘기하겠다.

---

## 4. 가장 어려웠던 것 — 세 곳이 각자 기억한다

페어링 상태를 **세 주체가 각자 저장**한다.

| 주체 | 저장소 | 기억하는 것 |
|---|---|---|
| ESP32 | NVS (`Preferences`) | `paired` 불리언 |
| 서버 | SQLite | `device_id ↔ fcm_token` 매핑 |
| 앱 | `SharedPreferences` | 내가 구독하는 `device_id` |

그리고 이 셋은 **반드시 어긋난다.**

앱을 삭제하면 앱의 기억만 사라진다. ESP32 를 공장 초기화하면 ESP32 의 기억만 사라진다.
서버는 둘 다 즉시 알 수 없다. 어긋나는 조합을 다 나열하면 경우의 수가 금방 불어난다.

여기서 한참 헤맸다. 각 주체가 서로에게 상태 변경을 통지하도록 만들려니 프로토콜이 계속
복잡해졌다. 결국 방향을 뒤집었다.

> **서버를 단일 진실 공급원으로 정하고, 나머지 둘은 자기가 깨어날 때 서버에 물어본다.**

통지를 없애고 대조로 바꾼 것이다. 상태 전이를 관리할 필요가 없어지고, 각 주체가 알아야
할 것은 "부팅/시동 시 서버에 물어본다" 하나로 줄었다.

### ESP32 — 부팅 시 대조

이걸 위해 엔드포인트를 하나 더 팠다. `GET /devices/count?device_id=` — 그 기기를
구독 중인 리스너 수를 돌려준다.

```cpp
void reconcilePairingWithServer() {
  const int count = queryListenerCount();
  const bool cached = isAlreadyPaired();     // NVS

  if (count < 0) {                  // 서버 불통 → 캐시를 믿는다
    if (!cached) startBleAdvertising();
    return;
  }
  if (count > 0) {                  // 구독자 있음
    if (!cached) savePaired();
    // BLE 광고 생략
  } else {                          // 구독자 없음
    if (cached) clearPaired();
    startBleAdvertising();
  }
}
```

세 갈래 모두 의미가 있다.

- `count > 0` → 이미 페어링됨. **BLE 를 아예 켜지 않는다** (뒤에 나올 힙 문제 때문에 중요).
- `count == 0` → 앱이 해제했거나 삭제됐다. **사용자가 기기를 만지지 않아도** 광고가 재개된다.
- `count < 0` (조회 실패) → 여기가 함정이었다. 서버 불통을 "페어링 안 됨" 으로 단정하면,
  WiFi 가 잠깐 불안정할 때마다 멀쩡히 동작 중인 기기가 BLE 를 켠다. **모르는 것과 아닌 것은
  다르다.** 모를 때는 캐시를 믿는다.

### 런타임 중에는 응답에 얹어서

부팅 시 대조만으로는 부족하다. 기기는 몇 달씩 안 꺼진다.

그래서 어차피 보내야 하는 요청의 응답을 신호로 썼다. `/ingest` 는 실제 전송 대상 수를
`targets` 로 돌려준다.

```cpp
if (code == 200) {
  int targets = r["targets"].as<int>();
  if (targets == 0) {                 // 리스너가 사라졌다
    if (isAlreadyPaired()) clearPaired();
    if (!bleActive) startBleAdvertising();
  }
}
```

**별도 폴링이 없다.** 상태 확인을 위한 트래픽을 따로 만들지 않고, 이미 흐르는 트래픽에
정보를 얹었다. 이게 이 프로젝트에서 개인적으로 가장 마음에 드는 부분이다.

### 앱 재설치 복구

앱을 지웠다 깔면 `SharedPreferences` 가 비어 있다. 하지만 FCM 토큰이 살아 있다면
서버는 매핑을 안다.

```dart
if (deviceId == null) {
  deviceId = await _recoverFromServer();   // GET /devices/lookup?fcm_token=
}
```

`/devices/lookup` 이 존재하는 유일한 이유다. 성공하면 사용자는 페어링 화면을 보지도 않고
바로 홈으로 들어간다.

### 해제는 서버 먼저, 그리고 실패를 삼킨다

```dart
try {
  await http.delete(...);            // 서버에서 먼저 제거
} catch (e) {
  debugPrint('unpair DELETE failed (continuing): $e');
}
await prefs.remove(_kDeviceIdKey);   // 실패해도 로컬은 정리
```

순서가 중요하다. 로컬을 먼저 지우고 서버 요청이 실패하면, 사용자는 "해제됨" 화면을 보는데
서버에는 남아 있고, 다시 해제를 누를 경로가 없다.

서버에 잔여 행이 남는 쪽이 낫다. 다음 `/ingest` 에서 FCM 이 `UnregisteredError` 를 주면
자동 정리되고, 안 되더라도 `targets` 불일치로 드러난다. **어긋남을 스스로 치유하는 경로가
이미 있으면, 실패를 삼켜도 된다.**

### 그리고 물리 버튼

```cpp
void maybeFactoryReset() {
  pinMode(FACTORY_RESET_PIN, INPUT_PULLUP);   // GPIO 0 = BOOT
  delay(50);
  if (digitalRead(FACTORY_RESET_PIN) == LOW) clearPaired();
}
```

`setup()` 의 **맨 첫 줄**, WiFi 연결보다 먼저다. WiFi 가 안 붙는 상황에서도 동작해야
의미가 있는 기능이기 때문이다. 네트워크에 의존하는 복구 경로만 있으면, 네트워크가
문제일 때 손쓸 방법이 없다.

---

## 5. 임베디드에서는 자원이 실제로 벽이 된다

여기부터는 서버 개발에서는 만날 일 없던 종류의 문제다.

### 힙 — BLE 와 TLS 는 사이가 나쁘다

BLE 스택과 TLS 핸드셰이크는 **둘 다 힙을 크게 먹는다.** 동시에 살려두면
`WiFiClientSecure` 가 핸드셰이크 중 메모리 부족으로 실패한다.

증상이 고약했다. 연결이 **가끔** 실패하고, 재부팅하면 잠깐 되기도 한다. 재현이 들쭉날쭉해서
네트워크 문제인지 인증서 문제인지 한참 의심했다. 로그에 힙 잔량을 찍고 나서야 보였다.

```cpp
Serial.printf("[http] free heap before POST=%u\n", ESP.getFreeHeap());
```

대응은 두 가지다.

**하나, 페어링이 끝나면 BLE 를 완전히 반환한다.**

```cpp
BLEDevice::getAdvertising()->stop();
BLEDevice::deinit(true);      // true 여야 힙이 실제로 돌아온다
```

`stop()` 만으로는 스택이 메모리를 쥐고 있다. `deinit(true)` 여야 한다.

**둘, 이미 페어링됐으면 BLE 를 애초에 켜지 않는다.** 앞서 부팅 시 대조에서 `count > 0` 이면
`startBleAdvertising()` 을 건너뛴다고 했는데, 이유가 여기 있다. 정상 운영 중인 기기는
BLE 스택을 한 번도 초기화하지 않는다.

곁다리로 하나 더. WRITE 콜백이 뜬 즉시 `deinit` 하면 앱 쪽에서 GATT 연결이 끊기며
오류로 처리되는 일이 있었다.

```cpp
if (pairSignalReceived) {
  delay(300);        // 앱의 disconnect 완료 대기
  savePaired();
}
```

300ms 는 실측으로 정했다. 우아하지 않지만 동작한다.

### 플래시 — 컴파일은 되는데 안 들어간다

BLE + WiFi + TLS 를 한 바이너리에 넣었더니:

```
Sketch uses 1786123 bytes (136%) of program storage space. Maximum is 1310720 bytes.
Error during build: text section exceeds available space in board
```

컴파일과 링크는 **성공**했다. 실패는 마지막 크기 검사에서 났다. 기본 파티션의 앱 영역이
1.31MB 인데 바이너리가 1.79MB 다.

`Huge APP (3MB No OTA)` 파티션으로 바꾸면 3.15MB 중 56% 로 들어간다. OTA 를 포기하고
얻는 공간인데, 어차피 USB 로 플래시하므로 손해가 없다.

```bash
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app esp32-firmware/PushRelay
```

당연하게도 이건 **어디에도 안 적혀 있었다.** 나중에 다른 PC 에서 빌드하다가 다시 만났다.
지금은 README 와 `platformio.ini` 에 박아뒀다.

---

## 6. 1GB VPS 에 올리기

상주 메모리는 **Caddy ~9MB + uvicorn ~67MB**. 1GB 에서 여유롭다.

nginx + certbot 대신 Caddy 를 골랐다. certbot 은 갱신 timer, 갱신 후 리로드 훅, 실패
알림을 각각 챙겨야 한다. Caddy 는 Caddyfile 에 도메인만 적으면 발급도 갱신도 알아서 한다.

```caddy
<push-host> {
	handle {
		reverse_proxy localhost:8000
	}
}
```

이게 전부다. FastAPI 는 `127.0.0.1:8000` 에 바인딩하고 systemd 로 띄운다.
방화벽은 22/80/443 만 연다.

여기서 한 번 데였다. **DNS 가 서버를 가리키기 전에 Caddy 를 리로드하면 안 된다.**
ACME 챌린지를 시도하다 실패를 반복하고, Let's Encrypt rate limit 에 걸린다.
A 레코드를 먼저 맞추고 리로드해야 한다.

그리고 ACME HTTP-01 챌린지는 **80 포트**를 쓴다. 443 만 열어두면 발급이 안 된다.

자세한 절차는 [docs/deployment.md](https://github.com/yeyebee/esp32-push-relay-showcase/blob/v1.1-blog/docs/deployment.md) 에 정리해뒀다.

---

## 7. 지금 알고 있는 한계

만들어놓고 보니 명확히 부족한 지점들이 있다. 감추는 것보다 적어두는 게 낫겠다.

**`/devices` 에 인증이 없다.** 이게 가장 큰 구멍이다. 남의 `device_id` 를 알면 거기에
리스너를 붙여 알림을 훔쳐볼 수 있다. `device_id` 는 MAC 기반이고 BLE 광고 이름에 그대로
들어가므로, 사거리 안에서는 관측 가능하다.

즉 **페어링의 보안은 "물리적 근접성" 하나에 걸려 있다.** 집 안에서 쓰는 개인 기기라
감수한 트레이드오프지만, 사용자가 늘면 계정 + JWT 가 필요하다.

**이벤트가 유실될 수 있다.** `/ingest` 가 실패하면 그 이벤트는 사라진다. 재시도 큐가 없다.
알림 성격상 늦은 알림보다 없는 알림이 나은 경우도 있어서 일단 뒀지만, 중요한 이벤트라면
NVS 에 큐를 두고 재시도해야 한다.

**관측성이 `journalctl` 뿐이다.** 푸시가 안 왔을 때 ESP32 가 안 보낸 건지, 서버가 실패한
건지, FCM 이 삼킨 건지 구분하려면 로그를 뒤져야 한다.

**SQLite + 워커 1개.** 지금 규모에서는 완벽하지만, 워커를 늘리려면 Postgres 로 먼저
옮겨야 한다. 순서를 뒤집으면 쓰기 잠금으로 고생한다.

---

## 8. 돌아보며

기술적으로 어려웠던 건 BLE 도 FCM 도 아니었다. **분산된 상태를 어떻게 일치시킬 것인가**
였다. 주체가 셋뿐인데도 경우의 수가 금방 불어났고, 각자가 서로에게 통지하도록 만들려던
초기 접근은 계속 복잡해지기만 했다.

풀린 지점은 **하나를 권위로 정하고 나머지는 물어보게** 바꾼 순간이었다. 통지를 대조로
바꾸니 상태 전이를 관리할 필요가 없어졌다. 각 주체가 알아야 할 규칙이 "깨어날 때 물어본다"
하나로 줄었다.

그리고 하나 더. **모르는 것과 아닌 것을 구분**하는 게 생각보다 자주 중요했다.
서버 조회 실패를 "페어링 안 됨" 으로 뭉개면 코드는 단순해지지만, 네트워크가 흔들릴 때마다
멀쩡한 기기가 이상하게 굴었다. `count < 0` 이라는 세 번째 갈래가 그래서 있다.

임베디드 쪽에서 배운 건 좀 더 원초적이다. 서버에서는 메모리가 부족하면 인스턴스를 키우면
되고 바이너리 크기는 생각해본 적도 없다. ESP32 에서는 **힙 몇십 KB 때문에 TLS 핸드셰이크가
실패하고, 480KB 때문에 빌드가 안 들어간다.** 자원이 추상화 뒤에 숨어 있지 않고 그대로
드러난다. 그게 불편했지만, 실제로 무엇이 얼마나 드는지 계속 의식하게 만들었다.

---

**코드**: [github.com/yeyebee/esp32-push-relay-showcase](https://github.com/yeyebee/esp32-push-relay-showcase) (`v1.1-blog`)

**더 읽을 것**
- [docs/architecture.md](https://github.com/yeyebee/esp32-push-relay-showcase/blob/v1.1-blog/docs/architecture.md) — 컴포넌트·API 계약·스택 선택 근거
- [docs/ble-pairing.md](https://github.com/yeyebee/esp32-push-relay-showcase/blob/v1.1-blog/docs/ble-pairing.md) — BLE 페어링과 상태 동기화 상세
- [docs/deployment.md](https://github.com/yeyebee/esp32-push-relay-showcase/blob/v1.1-blog/docs/deployment.md) — 1GB VPS 배포 절차
