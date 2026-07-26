from typing import Literal

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field

from app import db

router = APIRouter(prefix="/devices", tags=["devices"])


class DeviceRegistration(BaseModel):
    fcm_token: str = Field(min_length=1, max_length=4096)
    platform: Literal["android", "ios"]
    device_id: str = Field(min_length=1, max_length=64)


class DeviceDeletion(BaseModel):
    fcm_token: str = Field(min_length=1, max_length=4096)


@router.post("")
def register_device(payload: DeviceRegistration) -> dict[str, str | int]:
    db.upsert_device(payload.fcm_token, payload.platform, payload.device_id)
    return {"status": "registered", "total_devices": db.count_devices()}


@router.delete("")
def delete_device(payload: DeviceDeletion) -> dict[str, str | int]:
    removed = db.delete_by_token(payload.fcm_token)
    return {"status": "deleted", "removed": removed}


@router.get("/count")
def count_for_device(device_id: str = Query(min_length=1, max_length=64)) -> dict[str, int]:
    return {"count": db.count_by_device_id(device_id)}


@router.get("/lookup")
def lookup_device(
    fcm_token: str = Query(min_length=1, max_length=4096),
) -> dict[str, str | None]:
    info = db.lookup_by_token(fcm_token)
    if info is None:
        return {"device_id": None, "platform": None}
    return info
