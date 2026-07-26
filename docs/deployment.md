# 배포 — 1GB VPS 에 올리기

Ubuntu 24.04 / 1GB RAM / 공인 IP 하나짜리 VPS 기준. 실제 운영 중인 구성을 일반화한 것으로,
호스트명·경로·계정명은 placeholder 다.

전체 상주 메모리는 **Caddy ~9MB + uvicorn ~67MB**. 1GB 에서 여유롭다.

## 전제

- 도메인 하나와 그 A 레코드를 VPS 공인 IP 로 지정할 수 있을 것 (이하 `<push-host>`)
- 배포용 일반 사용자 (이하 `deploy`)
- 방화벽은 22 / 80 / 443 만 개방. FastAPI 는 `127.0.0.1:8000` 바인딩이라 외부 노출 없음

```bash
sudo ufw default deny incoming
sudo ufw allow 22/tcp  comment 'SSH'
sudo ufw allow 80/tcp  comment 'HTTP (ACME)'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw --force enable
```

> `ufw enable` 전에 22 를 먼저 열 것. 순서를 뒤집으면 SSH 가 끊긴다.

### SSH 는 키 전용으로 (순서가 중요)

22 번을 인터넷에 열어두면 무차별 대입이 **상시로** 들어온다. 100일 운영한 서버에서
fail2ban 기준 누적 실패 26,692회 / 차단 823건이었다. 비밀번호 인증을 끄면 이게 사라진다.

**키를 먼저 등록해 동작을 확인한 뒤에** 비밀번호를 꺼야 잠기지 않는다.

```bash
# [로컬] 키 등록 후, 키만으로 붙는지 검증 (BatchMode 가 비밀번호 프롬프트를 막아준다)
ssh-copy-id -i ~/.ssh/<key>.pub deploy@<host>
ssh -i ~/.ssh/<key> -o IdentitiesOnly=yes -o BatchMode=yes deploy@<host> 'echo OK'
```

`OK` 를 확인한 다음에만 진행한다. 원격에서 SSH 설정을 바꿀 때는 **자동 롤백을 걸어두면**
실수해도 기다리기만 하면 복구된다.

```bash
# [서버] 5분 뒤 자동 복구 예약
sudo cp /etc/ssh/sshd_config.d/01-hardening.conf /root/01-hardening.conf.bak
sudo systemd-run --on-active=300 --unit=ssh-auth-revert \
  /bin/bash -c 'cp /root/01-hardening.conf.bak /etc/ssh/sshd_config.d/01-hardening.conf && systemctl reload ssh'

sudo install -m 0644 /dev/stdin /etc/ssh/sshd_config.d/01-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
sudo sshd -t && sudo systemctl reload ssh
```

```bash
# [로컬] 새 연결로 양방향 검증
ssh -i ~/.ssh/<key> -o BatchMode=yes deploy@<host> 'echo KEY_OK'
ssh -o PubkeyAuthentication=no -o BatchMode=yes deploy@<host> 'echo SHOULD_FAIL'
#   → "Permission denied (publickey)" 가 나와야 정상
```

둘 다 기대대로면 `sudo systemctl stop ssh-auth-revert.timer` 로 안전망을 해제한다.

> `sshd_config.d/*.conf` 는 **먼저 매치된 값이 이긴다.** `99-` 처럼 뒤 순번 파일을 새로
> 만들면 앞 파일의 값에 밀려 적용되지 않는다. 인증 설정은 기존 파일을 직접 고칠 것.
>
> 키를 잃으면 SSH 로는 복구 불가다. 제공자 콘솔 접근 방법을 미리 확인하고 백업 키를 두자.

## 1. 패키지 · swap · 로그 정책

```bash
sudo apt-get update
sudo apt-get install -y python3 python3.12-venv sqlite3 curl git \
    debian-keyring debian-archive-keyring apt-transport-https
```

**swap** — 1GB 에서는 안전망이 필요하다. `fstab` 등록을 빠뜨리면 **재부팅 시 사라진다**
(실제로 겪었다. `swapon` 만 해두고 100일 뒤 재부팅했더니 0B 였다).

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo findmnt --verify --verbose | tail -3     # fstab 오류는 부팅 실패로 이어진다
systemctl list-units --type=swap              # swapfile.swap 이 보이면 영구화 성공
```

**로그 상한** — systemd journal 의 기본 정책은 **디스크의 10%** 라 사실상 무제한이다.
소형 VPS 를 100일 돌렸더니 journal 이 1.3GB, `/var/log` 전체가 1.7GB 였다.

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo install -m 0644 /dev/stdin /etc/systemd/journald.conf.d/99-size-limit.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=1G
SystemMaxFileSize=20M
MaxRetentionSec=1month
EOF
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=200M
```

`/var/log/dmesg` 는 배포판에 **logrotate 규칙이 없어서** UFW BLOCK 포트스캔 로그로 무한정
자란다 (92MB까지 갔다).

```bash
sudo install -m 0644 /dev/stdin /etc/logrotate.d/dmesg <<'EOF'
/var/log/dmesg {
    su root adm
    weekly
    rotate 2
    size 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
sudo logrotate -d /etc/logrotate.d/dmesg 2>&1 | grep -i error || echo OK
```

> `su root adm` 이 빠지면 `/var/log` 가 adm 그룹 쓰기 가능이라 logrotate 가 회전을 거부한다.
>
> 사용량은 **반드시 `sudo journalctl --disk-usage`** 로 확인할 것. sudo 없이 보면 사용자
> 가시 범위만 나와 실제보다 훨씬 작게 보인다 (109M 로 보였지만 실제 1.3G 였다).

## 2. Caddy

nginx + certbot 대신 Caddy 를 쓴 이유는 **인증서 발급·갱신을 설정 없이 처리**하기 때문이다.
certbot 은 cron/timer, 갱신 후 리로드 훅, 실패 알림을 각각 챙겨야 한다.

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy
```

`/etc/caddy/Caddyfile` — 이게 전부다:

```caddy
<push-host> {
	handle /caddy-test {
		respond "Caddy + HTTPS working" 200
	}
	handle {
		reverse_proxy localhost:8000
	}
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile   # "Valid configuration"
```

> **DNS 가 이 서버를 가리키기 전에는 리로드하지 말 것.** Caddy 가 ACME 챌린지를 시도하다
> 실패를 반복하면 Let's Encrypt rate limit 에 걸린다. A 레코드를 먼저 맞춘 뒤 리로드한다.

## 3. 애플리케이션

```bash
sudo mkdir -p -m 700 /home/deploy/secrets
# Firebase 서비스 계정 JSON 을 여기에 배치 — chmod 600, 저장소 밖
sudo chown deploy:deploy /home/deploy/secrets/firebase-adminsdk.json
sudo chmod 600 /home/deploy/secrets/firebase-adminsdk.json

cd /home/deploy/projects
git clone <repo-url> esp32-push-relay
cd esp32-push-relay/api-server

python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

cp .env.example .env && chmod 600 .env
# API_KEY 생성:
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

`.env`:

```ini
API_KEY=<32바이트 URL-safe 랜덤>
FIREBASE_CREDENTIALS_PATH=/home/deploy/secrets/firebase-adminsdk.json
DATABASE_PATH=./data/devices.db
```

DB 스키마는 따로 만들 필요가 없다. FastAPI lifespan 에서 `db.init()` 이
`CREATE TABLE IF NOT EXISTS` + 필요 시 `ALTER TABLE` 로 알아서 맞춘다.

## 4. systemd

`/etc/systemd/system/esp32-push-relay.service`:

```ini
[Unit]
Description=ESP32 Push Relay FastAPI server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/home/deploy/projects/esp32-push-relay/api-server
ExecStart=/home/deploy/projects/esp32-push-relay/api-server/.venv/bin/uvicorn \
          app.main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now esp32-push-relay
curl http://127.0.0.1:8000/health      # {"status":"ok","devices":0}
```

`--workers 1` 이 기본이다. SQLite 쓰기 동시성 때문에 워커를 늘리려면 Postgres 로 먼저 옮겨야 한다.

## 5. DNS 와 첫 인증서

A 레코드를 VPS 공인 IP 로 지정하고 (TTL 은 300 정도로 낮게 두면 나중에 옮기기 편하다),
전파를 확인한 뒤에 Caddy 를 리로드한다.

```bash
dig @8.8.8.8 +short A <push-host>       # VPS IP 가 나올 때까지
sudo systemctl reload caddy
sudo journalctl -u caddy -n 30          # "certificate obtained successfully"
curl https://<push-host>/health
```

## 검증

```bash
# 잘못된 키 → 401
curl -o /dev/null -w '%{http_code}\n' -X POST https://<push-host>/ingest \
  -H 'Content-Type: application/json' -H 'X-API-Key: wrong' \
  -d '{"title":"t","body":"b","device_id":"A1B2C3"}'

# device_id 누락 → 422
curl -o /dev/null -w '%{http_code}\n' -X POST https://<push-host>/ingest \
  -H 'Content-Type: application/json' -H "X-API-Key: $KEY" \
  -d '{"title":"t","body":"b"}'

# 인증서
openssl s_client -connect <push-host>:443 -servername <push-host> </dev/null 2>/dev/null \
  | grep -E 'subject|issuer'
```

## 운영

```bash
sudo systemctl status esp32-push-relay
sudo journalctl -u esp32-push-relay -f
sudo journalctl -u caddy -n 50

sqlite3 data/devices.db \
  "SELECT device_id, platform, substr(fcm_token,1,20)||'...', updated_at FROM devices"
```

**API 키 회전** — `.env` 수정 → `systemctl restart esp32-push-relay` →
**펌웨어 `secrets.h` 도 같은 값으로 바꾸고 재플래시**. 둘이 어긋나면 `/ingest` 가 401 이 된다.

**백업** — 자동 백업은 없다. DB 가 날아가도 각 앱이 다음 시동에 `POST /devices` 로
재등록하므로 복구된다. 정말 잃으면 곤란한 것은 Firebase 서비스 계정 JSON 하나뿐이고,
이건 콘솔에서 재발급할 수 있다.

## 겪은 것들

**서비스가 안 뜬다** — 대부분 `.env` 누락/손상, Firebase JSON 경로 오류, venv 깨짐 셋 중 하나다.
`journalctl -u esp32-push-relay -n 80` 이 바로 알려준다.

**HTTPS 가 안 된다** — 십중팔구 DNS 가 아직 전파 안 됐거나 80 포트가 막혀 있다.
ACME HTTP-01 챌린지는 80 을 쓴다. 443 만 열어두면 발급이 안 된다.

**정기 점검에서 볼 것** — 100일 무재부팅으로 굴려보고 정리한 목록이다.

```bash
uname -r; uptime -p
free -h                                     # swap 이 0B 면 fstab 이 안 걸린 것
df -h /
sudo journalctl --disk-usage                # sudo 필수. 상한 근처에서 안정적인가
sudo du -sh /var/log                        # 다시 부풀면 새 원인이 생긴 것
[ -f /var/run/reboot-required ] && echo '재부팅 필요'
sudo fail2ban-client status sshd            # 키 전용 전환 후 증가폭이 줄었는가
```

**커널 업데이트를 100일씩 미루지 말 것.** 한 번 밀리기 시작하면 대기 목록이 쌓이고
(6.8.0-87 로 돌면서 6.8.0-136 까지 대기 중이었다) 재부팅 부담만 커진다.

**서버 이전 시** — 옛 서버를 끄지 말고 새 서버를 완전히 세운 뒤 DNS 만 돌린다.
문제가 생기면 A 레코드 롤백 한 번으로 원복된다 (TTL 이 낮아야 이게 빠르다).
`/var/lib/caddy` 를 통째로 옮기면 인증서를 재발급하지 않아 rate limit 을 피할 수 있다.
