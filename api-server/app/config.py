from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    api_key: str
    firebase_credentials_path: str
    database_path: str = "./data/devices.db"


settings = Settings()
