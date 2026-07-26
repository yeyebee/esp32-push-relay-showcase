# ESP32 Push Relay — 공개 스냅샷

ESP32 의 이벤트를 자체 VPS 를 거쳐 스마트폰 푸시 알림으로 띄우는 개인 IoT 프로젝트.
**BLE 로 기기를 페어링하고, 서버를 페어링 상태의 진실 공급원으로 삼는 구조**가 핵심입니다.

```
┌──────────┐  ① BLE 페어링   ┌────────────────┐
│  ESP32   │ ◀─────────────▶ │  Flutter 앱    │
│          │                 │ (Android/iOS)  │
└────┬─────┘                 └───────┬────────┘
     │                               │
     │ ② HTTPS POST /ingest          │ ③ POST /devices (FCM 토큰 등록)
     │    { title, body, device_id } │    { fcm_token, platform, device_id }
     ▼                               ▼
   ┌────────────────────────────────────┐
   │  VPS — Caddy(:443) → FastAPI(:8000)│
   │  SQLite: device_id ↔ FCM 토큰 매핑 │
   └─────────────────┬──────────────────┘
                     │ ④ Firebase Admin SDK
                     ▼
                  ┌─────┐   푸시   ┌────────────────┐
                  │ FCM │ ───────▶ │  Flutter 앱    │
                  └─────┘          └────────────────┘
```

## 읽는 순서

| 문서 | 내용 |
|---|---|
| [blog-post.md](./blog-post.md) | **발행본.** 왜 이렇게 만들었는지의 서사 — 설계 결정과 그 과정에서 틀렸던 것들 |
| [docs/architecture.md](./docs/architecture.md) | 컴포넌트·데이터 흐름·API 계약·스택 선택 근거 |
| [docs/ble-pairing.md](./docs/ble-pairing.md) | 이 프로젝트의 고유 부분 — BLE 프로비저닝과 3자 상태 동기화 |
| [docs/deployment.md](./docs/deployment.md) | 1GB VPS 에 Caddy + systemd 로 올리는 절차 |

## 코드

| 디렉토리 | 스택 | 비고 |
|---|---|---|
| [`api-server/`](./api-server) | Python 3.12 · FastAPI · Firebase Admin SDK · SQLite | 전체 포함 |
| [`esp32-firmware/`](./esp32-firmware) | Arduino (ESP32) · ArduinoJson · BLE · Preferences(NVS) | 스케치 전체 포함 |
| [`flutter-app/`](./flutter-app) | Flutter · firebase_messaging · flutter_blue_plus | `lib/` 만 — `android/`·`ios/` 스캐폴딩 제외 |

## 이 저장소에 대해

블로그 글의 **참조·인용용 스냅샷**입니다. 실 개발 저장소는 별도 private 이며, 이 저장소는
그로부터 익명화해 옮긴 것입니다. 다음은 포함되어 있지 않습니다:

- 실 도메인·공인 IP·서버 계정명 등 인프라 좌표 (`<push-host>` 등 placeholder 로 치환)
- Firebase 프로젝트 ID·서비스 계정 키·API 키·WiFi 자격증명
- 운영 런북 (서버 이전 절차, 사고 복구 체크리스트 등)

따라서 **clone 해서 그대로 실행되지는 않습니다.** `secrets.h` 와 `.env` 를 직접 채우고
Firebase 프로젝트를 연결해야 합니다. 각 디렉토리의 README 에 필요한 값이 정리되어 있습니다.

발행 시점 스냅샷은 [`v1.0-blog`](../../tree/v1.0-blog) 태그로 고정되어 있습니다. 블로그 글의
코드 인용은 이 태그를 기준으로 합니다 — 이후 커밋으로 내용이 달라져도 원문 링크는 유지됩니다.

## 라이선스

[MIT](./LICENSE). 자유롭게 참조·개조하셔도 됩니다.
