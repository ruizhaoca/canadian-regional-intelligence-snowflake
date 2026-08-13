"""Environment-backed application settings."""

from pydantic import HttpUrl
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    azure_storage_account_url: HttpUrl
    azure_storage_file_system: str = "landing"
    azure_storage_prefix: str = "statcan"
    log_level: str = "INFO"

