import logging

import firebase_admin
from firebase_admin import credentials, exceptions, messaging
from firebase_admin.messaging import SenderIdMismatchError, UnregisteredError

from app import db
from app.config import settings

# 영구적으로 해당 토큰을 사용할 수 없게 만드는 에러들 — DB에서 삭제 안전.
# - UnregisteredError: 앱 삭제/토큰 만료
# - SenderIdMismatchError: 다른 Firebase 프로젝트의 토큰
# - InvalidArgumentError(per-token): FCM이 "토큰 포맷 자체가 이상"으로 판정
#   (메시지 payload 자체가 잘못됐다면 multicast 호출 전체가 예외로 터지므로,
#    per-token InvalidArgumentError 는 토큰 쪽 문제로 간주.)
_PRUNABLE = (UnregisteredError, SenderIdMismatchError, exceptions.InvalidArgumentError)

logger = logging.getLogger(__name__)

_app: firebase_admin.App | None = None


def _ensure_initialized() -> firebase_admin.App:
    global _app
    if _app is None:
        cred = credentials.Certificate(settings.firebase_credentials_path)
        _app = firebase_admin.initialize_app(cred)
    return _app


def send_to_device(device_id: str, title: str, body: str, data: dict[str, str]) -> dict[str, int]:
    _ensure_initialized()
    tokens = db.list_tokens_by_device_id(device_id)
    if not tokens:
        return {"targets": 0, "sent": 0, "failed": 0, "pruned": 0}

    message = messaging.MulticastMessage(
        notification=messaging.Notification(title=title, body=body),
        data=data,
        tokens=tokens,
    )
    resp = messaging.send_each_for_multicast(message)

    stale: list[str] = []
    for token, r in zip(tokens, resp.responses):
        if r.success:
            continue
        # FCM 이 "해당 토큰은 더 이상 유효하지 않음" 이라고 답한 경우만 삭제.
        # 일시적 네트워크 오류·쿼터 초과 등은 그대로 둠 (다음 전송에서 재시도).
        if isinstance(r.exception, _PRUNABLE):
            stale.append(token)
        else:
            logger.warning("FCM send failed (kept): token_prefix=%s err=%r",
                           token[:12], r.exception)
    pruned = db.delete_tokens(stale) if stale else 0

    return {
        "targets": len(tokens),
        "sent": resp.success_count,
        "failed": resp.failure_count,
        "pruned": pruned,
    }
