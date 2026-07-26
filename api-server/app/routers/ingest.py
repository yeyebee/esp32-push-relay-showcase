from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from app.config import settings
from app.services import fcm

router = APIRouter(prefix="/ingest", tags=["ingest"])


class IngestPayload(BaseModel):
    title: str
    body: str
    device_id: str = Field(min_length=1, max_length=64)
    data: dict[str, str] | None = None


@router.post("")
def ingest_event(
    payload: IngestPayload,
    x_api_key: str = Header(..., alias="X-API-Key"),
) -> dict[str, str | int]:
    if x_api_key != settings.api_key:
        raise HTTPException(status_code=401, detail="invalid api key")

    result = fcm.send_to_device(
        device_id=payload.device_id,
        title=payload.title,
        body=payload.body,
        data=payload.data or {},
    )
    return {"status": "accepted", **result}
