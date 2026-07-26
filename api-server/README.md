# api-server

ESP32 이벤트 수신 → FCM 푸시 릴레이. Python 3.12 + FastAPI.

## 디렉토리 구조

```
api-server/
├── app/
│   ├── main.py           # FastAPI 엔트리
│   ├── config.py         # 환경변수 로딩 (pydantic-settings)
│   ├── routers/
│   │   ├── ingest.py     # POST /ingest  (ESP32 → 서버)
│   │   └── devices.py    # POST /devices (Flutter 앱 → 토큰 등록)
│   └── services/
│       └── fcm.py        # Firebase Admin SDK 래퍼
├── requirements.txt
└── .env.example
```

## 로컬 실행

```bash
cd api-server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env
# .env 편집: API_KEY, FIREBASE_CREDENTIALS_PATH

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## 엔드포인트 (초안)

| 메서드 | 경로 | 용도 | 인증 |
|---|---|---|---|
| GET | `/health` | 헬스체크 + 등록 디바이스 수 | 없음 |
| POST | `/devices` | FCM 토큰 UPSERT (`fcm_token`, `platform`, `device_id`) | 없음 |
| DELETE | `/devices` | 토큰 해제 (`fcm_token`) | 없음 |
| GET | `/devices/count?device_id=` | 해당 기기에 붙은 리스너 수 — **펌웨어 페어링 동기화용** | 없음 |
| GET | `/devices/lookup?fcm_token=` | 토큰으로 `device_id` 역조회 — 앱 재설치 복구용 | 없음 |
| POST | `/ingest` | ESP32 이벤트 → 해당 `device_id` 의 토큰들에 푸시 | `X-API-Key` 헤더 |

`/ingest` 응답: `{"status":"accepted","targets":N,"sent":N,"failed":N,"pruned":N}`.
`targets` 는 그 기기에 등록된 리스너 수이고, 펌웨어는 이 값이 `0` 이면 페어링이 끊긴 것으로
판단해 BLE 광고를 재개한다 ([../docs/ble-pairing.md](../docs/ble-pairing.md)).

> 인증 모델은 MVP 수준이다. `/ingest` 만 공유 비밀로 막고 `/devices` 계열은 열려 있다.
> 토큰 자체가 식별자 역할을 하고 임의 `device_id` 로 등록해봐야 남의 푸시를 가로챌 수는
> 없지만, 남의 `device_id` 에 리스너를 붙여 알림을 훔쳐보는 것은 가능하다.
> 실사용 규모가 커지면 사용자 계정 + JWT 가 필요하다.

## 배포

systemd + Caddy 구성은 [../docs/deployment.md](../docs/deployment.md) 참조.
자격증명 파일(`firebase-adminsdk.json`)은 저장소 밖에 두고 `.env` 에는 경로만 지정한다 (chmod 600).
