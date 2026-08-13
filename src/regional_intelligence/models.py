"""Typed acquisition metadata models."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class ArtifactManifest(BaseModel):
    """Integrity metadata for an object in an immutable landing batch."""

    model_config = ConfigDict(frozen=True)

    role: Literal["source_archive", "data_csv"]
    path: str
    media_type: str
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    size_bytes: int = Field(gt=0)


class BatchManifest(BaseModel):
    """Metadata stored beside each immutable source object."""

    model_config = ConfigDict(frozen=True)

    schema_version: str = "1.0"
    batch_id: str
    table_id: str
    product_id: str
    subject: str
    source_url: str
    source_last_modified: str | None = None
    source_last_modified_utc: datetime | None = None
    ingested_at_utc: datetime
    source_archive: ArtifactManifest
    data_csv: ArtifactManifest
    source_record_count: int = Field(gt=0)
    source_columns: tuple[str, ...]
    status: Literal["READY"] = "READY"


class AcquisitionResult(BaseModel):
    """Concise outcome emitted by one dataset acquisition."""

    model_config = ConfigDict(frozen=True)

    table_id: str
    batch_id: str
    outcome: Literal["CREATED", "SKIPPED"]
    manifest_path: str
    ready_path: str
