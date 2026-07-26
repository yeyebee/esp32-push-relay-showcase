from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import db
from app.routers import devices, ingest


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init()
    yield


app = FastAPI(title="ESP32 Push Relay", version="0.1.0", lifespan=lifespan)

app.include_router(devices.router)
app.include_router(ingest.router)


@app.get("/health")
def health() -> dict[str, str | int]:
    return {"status": "ok", "devices": db.count_devices()}
