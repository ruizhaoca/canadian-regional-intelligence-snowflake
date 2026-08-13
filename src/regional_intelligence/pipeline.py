"""One-table acquisition workflow with immutable, restart-safe publication."""

from __future__ import annotations

import csv
import io
import json
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from pathlib import Path

from pydantic import ValidationError

from regional_intelligence.archive import extract_data_csv
from regional_intelligence.catalog import Dataset
from regional_intelligence.models import AcquisitionResult, ArtifactManifest, BatchManifest
from regional_intelligence.statscan import StatsCanClient
from regional_intelligence.storage import LandingStore, ObjectIntegrityError, sha256_bytes


def acquire_dataset(
    dataset: Dataset,
    *,
    client: StatsCanClient,
    store: LandingStore,
    work_dir: Path,
    prefix: str = "statcan",
    now: datetime | None = None,
) -> AcquisitionResult:
    """Download, validate, and atomically publish one content-addressed batch."""

    work_dir.mkdir(parents=True, exist_ok=True)
    source_url = client.resolve_download_url(dataset.product_id)
    archive = client.download(source_url, work_dir / f"{dataset.product_id}.zip")
    batch_id = f"{dataset.product_id}-{archive.sha256[:16]}"
    batch_root = f"{prefix.strip('/')}/{dataset.table_id}/batch_id={batch_id}"
    archive_path = f"{batch_root}/source.zip"
    data_path = f"{batch_root}/data.csv"
    manifest_path = f"{batch_root}/manifest.json"
    ready_path = f"{batch_root}/_READY.csv"

    if store.exists(ready_path):
        _validate_existing_manifest(store, manifest_path, batch_id, archive.sha256)
        return AcquisitionResult(
            table_id=dataset.table_id,
            batch_id=batch_id,
            outcome="SKIPPED",
            manifest_path=manifest_path,
            ready_path=ready_path,
        )

    prepared = extract_data_csv(archive.path, work_dir / f"{dataset.product_id}.csv")
    store.put_file(archive_path, archive.path, archive.sha256)
    store.put_file(data_path, prepared.path, prepared.sha256)

    manifest = BatchManifest(
        batch_id=batch_id,
        table_id=dataset.table_id,
        product_id=dataset.product_id,
        subject=dataset.subject,
        source_url=archive.source_url,
        source_last_modified=archive.source_last_modified,
        source_last_modified_utc=_http_datetime(archive.source_last_modified),
        ingested_at_utc=now or datetime.now(UTC),
        source_archive=ArtifactManifest(
            role="source_archive",
            path=archive_path,
            media_type="application/zip",
            sha256=archive.sha256,
            size_bytes=archive.size_bytes,
        ),
        data_csv=ArtifactManifest(
            role="data_csv",
            path=data_path,
            media_type="text/csv",
            sha256=prepared.sha256,
            size_bytes=prepared.size_bytes,
        ),
        source_record_count=prepared.record_count,
        source_columns=prepared.columns,
    )

    if store.exists(manifest_path):
        existing = _validate_existing_manifest(store, manifest_path, batch_id, archive.sha256)
        manifest = existing
    else:
        manifest_bytes = _json_bytes(manifest.model_dump(mode="json"))
        try:
            store.put_bytes(manifest_path, manifest_bytes, sha256_bytes(manifest_bytes))
        except ObjectIntegrityError:
            # Another invocation can win the write race with a different ingestion timestamp.
            manifest = _validate_existing_manifest(
                store, manifest_path, batch_id, archive.sha256
            )

    ready_bytes = _ready_csv_bytes(manifest, manifest_path)
    created = store.put_bytes(ready_path, ready_bytes, sha256_bytes(ready_bytes))
    return AcquisitionResult(
        table_id=dataset.table_id,
        batch_id=batch_id,
        outcome="CREATED" if created else "SKIPPED",
        manifest_path=manifest_path,
        ready_path=ready_path,
    )


def _validate_existing_manifest(
    store: LandingStore,
    manifest_path: str,
    batch_id: str,
    archive_sha256: str,
) -> BatchManifest:
    try:
        manifest = BatchManifest.model_validate_json(store.read_bytes(manifest_path))
    except (FileNotFoundError, ValidationError) as error:
        raise ObjectIntegrityError(
            f"Ready or partial batch has no valid manifest at {manifest_path}"
        ) from error
    if manifest.batch_id != batch_id or manifest.source_archive.sha256 != archive_sha256:
        raise ObjectIntegrityError(f"Manifest does not match batch at {manifest_path}")
    return manifest


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def _ready_csv_bytes(manifest: BatchManifest, manifest_path: str) -> bytes:
    output = io.StringIO(newline="")
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(
        [
            "table_id",
            "batch_id",
            "subject",
            "source_url",
            "source_last_modified_utc",
            "ingested_at_utc",
            "source_archive_sha256",
            "data_csv_sha256",
            "source_record_count",
            "data_path",
            "manifest_path",
        ]
    )
    writer.writerow(
        [
            manifest.table_id,
            manifest.batch_id,
            manifest.subject,
            manifest.source_url,
            (
                manifest.source_last_modified_utc.isoformat()
                if manifest.source_last_modified_utc
                else None
            ),
            manifest.ingested_at_utc.isoformat(),
            manifest.source_archive.sha256,
            manifest.data_csv.sha256,
            manifest.source_record_count,
            manifest.data_csv.path,
            manifest_path,
        ]
    )
    return output.getvalue().encode()


def _http_datetime(value: str | None) -> datetime | None:
    if value is None:
        return None
    try:
        parsed = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)
