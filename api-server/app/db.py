import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from app.config import settings

_BASE_SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    fcm_token   TEXT PRIMARY KEY,
    platform    TEXT NOT NULL CHECK(platform IN ('android','ios')),
    device_id   TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_devices_updated_at ON devices(updated_at);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def init() -> None:
    path = Path(settings.database_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with _connect() as conn:
        conn.executescript(_BASE_SCHEMA)
        cols = [r[1] for r in conn.execute("PRAGMA table_info(devices)").fetchall()]
        if "device_id" not in cols:
            conn.execute("ALTER TABLE devices ADD COLUMN device_id TEXT")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_devices_device_id ON devices(device_id)"
        )


@contextmanager
def _connect() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(settings.database_path)
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def upsert_device(fcm_token: str, platform: str, device_id: str) -> None:
    now = _now()
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO devices(fcm_token, platform, device_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(fcm_token) DO UPDATE SET
                platform   = excluded.platform,
                device_id  = excluded.device_id,
                updated_at = excluded.updated_at
            """,
            (fcm_token, platform, device_id, now, now),
        )


def list_tokens_by_device_id(device_id: str) -> list[str]:
    with _connect() as conn:
        rows = conn.execute(
            "SELECT fcm_token FROM devices WHERE device_id = ?", (device_id,)
        ).fetchall()
    return [r[0] for r in rows]


def count_devices() -> int:
    with _connect() as conn:
        (n,) = conn.execute("SELECT COUNT(*) FROM devices").fetchone()
    return n


def count_by_device_id(device_id: str) -> int:
    with _connect() as conn:
        (n,) = conn.execute(
            "SELECT COUNT(*) FROM devices WHERE device_id = ?", (device_id,)
        ).fetchone()
    return n


def delete_by_token(fcm_token: str) -> int:
    with _connect() as conn:
        cur = conn.execute("DELETE FROM devices WHERE fcm_token = ?", (fcm_token,))
        return cur.rowcount or 0


def lookup_by_token(fcm_token: str) -> dict[str, str] | None:
    with _connect() as conn:
        row = conn.execute(
            "SELECT device_id, platform FROM devices WHERE fcm_token = ?",
            (fcm_token,),
        ).fetchone()
    if not row or row[0] is None:
        return None
    return {"device_id": row[0], "platform": row[1]}


def delete_tokens(tokens: list[str]) -> int:
    if not tokens:
        return 0
    with _connect() as conn:
        cur = conn.executemany(
            "DELETE FROM devices WHERE fcm_token = ?",
            [(t,) for t in tokens],
        )
        return cur.rowcount or 0
