# 아키텍처

## 문제 정의

ESP32 에 붙은 센서가 이벤트를 감지했을 때(도어벨, 감지기 등) 스마트폰에 즉시 알림을 띄운다.
집 밖에서도 받아야 하므로 로컬 네트워크 내 통신으로는 부족하고, 앱이 꺼져 있어도 도착해야 한다.

→ **FCM(Firebase Cloud Messaging)** 을 쓰면 앱이 죽어 있어도 OS 레벨에서 알림이 뜬다.
그런데 FCM 으로 푸시를 보내려면 **서버 측 자격증명**(Firebase 서비스 계정 키)이 필요하고,
이건 ESP32 펌웨어에 넣을 수 없다 — 플래시를 덤프하면 그대로 새어나가고, 유출 시 Firebase
프로젝트 전체가 뚫린다.

그래서 중계 서버가 필요하다. ESP32 는 **약한 비밀**(회전 가능한 API 키)만 들고,
**강한 비밀**(서비스 계정 키)은 서버에만 둔다.

## 구성

```
┌──────────┐  ① BLE 페어링   ┌────────────────┐
│  ESP32   │ ◀─────────────▶ │  Flutter 앱    │
└────┬─────┘                 └───────┬────────┘
     │ ② POST /ingest                │ ③ POST /devices
     │   X-API-Key                   │   { fcm_token, platform, device_id }
     │   { title, body, device_id }  │
     ▼                               ▼
   ┌────────────────────────────────────┐
   │  Caddy :443  (TLS 종단, ACME 자동) │
   │       └─▶ FastAPI 127.0.0.1:8000   │
   │  SQLite — device_id ↔ FCM 토큰      │
   └─────────────────┬──────────────────┘
                     │ ④ Firebase Admin SDK
                     ▼  send_each_for_multicast
                  ┌─────┐          ┌────────────────┐
                  │ FCM │ ───────▶ │  Flutter 앱    │
                  └─────┘          └────────────────┘
```

| 컴포넌트 | 스택 | 역할 |
|---|---|---|
| 펌웨어 | Arduino (ESP32) + ArduinoJson + BLE + Preferences | WiFi 연결, BLE 페어링, HTTPS POST |
| API 서버 | Python 3.12 + FastAPI + Firebase Admin SDK | 이벤트 수신, 토큰 관리, FCM 릴레이 |
| 저장소 | SQLite (단일 파일) | `device_id ↔ fcm_token` 매핑 |
| TLS 종단 | Caddy | Let's Encrypt 자동 발급·갱신, 리버스 프록시 |
| 앱 | Flutter + firebase_messaging + flutter_blue_plus | 토큰 등록, BLE 페어링, 알림 수신 |

## 데이터 모델

```sql
CREATE TABLE devices (
    fcm_token   TEXT PRIMARY KEY,   -- 폰 하나 = 행 하나
    platform    TEXT NOT NULL CHECK(platform IN ('android','ios')),
    device_id   TEXT,               -- 이 폰이 구독하는 ESP32
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX idx_devices_device_id  ON devices(device_id);
CREATE INDEX idx_devices_updated_at ON devices(updated_at);
```

`fcm_token` 을 PK 로 잡은 것이 핵심이다. FCM 토큰은 **폰 + 앱 설치 인스턴스**를 유일하게
가리키므로, 같은 폰이 앱을 재설치하면 새 행이 되고 옛 행은 FCM 이 `UnregisteredError` 로
알려줄 때 정리된다.

`device_id` 는 ESP32 의 **MAC 주소 끝 3바이트를 대문자 hex 로 표기한 6자**다 (예: `A1B2C3`).
공장 출하 시 부여되는 값이라 별도 프로비저닝 없이 기기를 유일하게 식별할 수 있고,
BLE 광고 이름(`ESP32-A1B2C3`)에도 그대로 쓰여 앱이 스캔 결과에서 바로 읽어낸다.

`device_id` 컬럼이 `NOT NULL` 이 아닌 것은 초기 버전(전체 브로드캐스트)에서 마이그레이션한
흔적이다. `db.init()` 이 `PRAGMA table_info` 로 컬럼 존재를 확인하고 없으면 `ALTER TABLE` 한다.

**N:1 관계다.** 한 ESP32 에 여러 폰이 붙을 수 있고(가족 구성원), 한 폰은 하나의 ESP32 를
구독한다. 후자는 앱 UI 의 제약이지 스키마의 제약은 아니다.

## API 계약

| 메서드 | 경로 | 인증 | 용도 |
|---|---|---|---|
| GET | `/health` | — | 헬스체크 + 총 등록 수 |
| POST | `/devices` | — | 토큰 UPSERT (`ON CONFLICT(fcm_token) DO UPDATE`) |
| DELETE | `/devices` | — | 페어링 해제 |
| GET | `/devices/count?device_id=` | — | 그 기기의 리스너 수 — **펌웨어가 부팅 때 조회** |
| GET | `/devices/lookup?fcm_token=` | — | 토큰 → `device_id` 역조회 — **앱 재설치 복구** |
| POST | `/ingest` | `X-API-Key` | 이벤트 → 해당 기기의 토큰들에 푸시 |

`/ingest` 는 `device_id` 를 **필수**로 받는다. 이게 빠지면 FastAPI 가 422 로 거절한다.
초기 버전은 등록된 모든 토큰에 브로드캐스트했는데, 기기가 둘 이상이 되는 순간 무의미해져서
`device_id` 를 도입했다. 이 필드를 필수로 만든 덕분에 나중에 구버전 펌웨어를 식별할 수 있었다
([blog-post.md](../blog-post.md) 3장).

## 설계 결정과 근거

| 항목 | 선택 | 근거 |
|---|---|---|
| 서버 언어 | Python 3.12 + FastAPI | Firebase Admin SDK 공식 지원. 1GB RAM 에서 ~50MB RSS |
| 프로토콜 | HTTPS REST | 443 하나로 끝. MQTT 였다면 브로커 + 포트 + 인증 체계가 추가로 필요 |
| 저장소 | SQLite | 행 수가 사람 수 단위. 파일 하나라 백업이 `cp` |
| TLS 종단 | Caddy | 설정 4줄로 Let's Encrypt 자동 발급·갱신. ~9MB |
| ESP32 TLS | 루트 CA 1개 고정 | 번들 전체는 플래시 낭비. ISRG Root X1 하나면 충분 |
| 페어링 | BLE + 서버 대조 | 아래 참조 |

### 왜 MQTT 가 아닌가

ESP32 IoT 예제는 대개 MQTT 를 쓴다. 여기서 REST 를 고른 이유:

- 트래픽이 **이벤트 발생 시에만** 흐른다. 상시 연결을 유지할 이유가 없다.
- MQTT 를 쓰면 브로커(Mosquitto 등) + 방화벽 포트 + 브로커 인증이 늘어난다. 1GB VPS 에서
  구성 요소 하나를 더 늘리는 비용이 이득보다 크다.
- 서버 → ESP32 방향 명령이 필요 없다. 단방향이면 REST 로 충분하다.

양방향 제어가 필요해지면 그때 MQTT 를 얹는 게 맞다.

### 왜 앱이 직접 ESP32 와 통신하지 않는가

BLE 로 직접 연결하면 집 안에서만 되고, 앱이 꺼져 있으면 못 받는다.
로컬 WiFi 직결도 같은 한계 + NAT 통과 문제가 붙는다.
**"앱이 죽어 있어도, 집 밖에서도 받아야 한다"** 는 요구가 FCM 을, FCM 이 중계 서버를 강제한다.

BLE 는 그래서 **알림 경로가 아니라 페어링 경로로만** 쓴다 — [ble-pairing.md](./ble-pairing.md).

## 보안 모델 (그리고 그 한계)

- **ESP32 → 서버**: `X-API-Key` 공유 비밀. 펌웨어에 하드코딩되지만 `secrets.h` 는 git 밖이고,
  유출 시 서버 `.env` 수정 + 재플래시로 회전한다.
- **앱 → 서버**: **인증 없음.** MVP 수준의 의도적 타협이다.
- **서버 → FCM**: 서비스 계정 JSON. 저장소 밖 `chmod 600`, `.env` 에 경로만.
- **TLS**: Caddy 자동. 펌웨어는 ISRG Root X1 을 바이너리에 고정해 검증한다
  (`TLS_INSECURE = false`). 개발용 `setInsecure()` 는 프로덕션에서 쓰지 않는다.

**한계를 분명히 하자면**: `/devices` 가 열려 있으므로 남의 `device_id` 를 알면 거기에
리스너를 붙여 알림을 훔쳐볼 수 있다. `device_id` 는 MAC 기반이라 BLE 스캔 사거리 안에서는
관측 가능하다. 개인용 규모에서 감수한 트레이드오프이고, 실사용자가 늘면 계정 + JWT 가 필요하다.

## 확장했을 때 먼저 깨질 곳

| 지점 | 한계 | 대응 |
|---|---|---|
| SQLite + uvicorn `--workers 1` | 쓰기 동시성 | 워커를 늘리기 전에 Postgres 로 |
| `/devices` 무인증 | 알림 도청 | 사용자 계정 + JWT |
| 이벤트 유실 | `/ingest` 실패 시 재시도 없음 | 펌웨어 측 재시도 큐 (NVS) |
| 관측성 | `journalctl` 뿐 | 구조화 로그 + 알림 |
| 백업 | 없음 | `sqlite3 .backup` cron. 단 토큰은 각 앱이 재등록하면 복원됨 |
