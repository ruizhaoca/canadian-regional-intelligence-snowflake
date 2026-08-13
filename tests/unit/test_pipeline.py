import csv
import io
from datetime import UTC, datetime
from pathlib import Path
from typing import cast
from zipfile import ZipFile

from regional_intelligence.catalog import DATASETS
from regional_intelligence.pipeline import acquire_dataset
from regional_intelligence.statscan import DownloadedFile, StatsCanClient
from regional_intelligence.storage import LocalLandingStore


class FakeStatsCanClient:
    def __init__(self, archive: Path) -> None:
        self.archive = archive

    def resolve_download_url(self, product_id: str) -> str:
        return f"https://example.test/{product_id}.zip"

    def download(self, source_url: str, destination: Path) -> DownloadedFile:
        content = self.archive.read_bytes()
        destination.write_bytes(content)
        import hashlib

        return DownloadedFile(
            path=destination,
            source_url=source_url,
            source_last_modified="Wed, 14 Jan 2026 13:30:47 GMT",
            sha256=hashlib.sha256(content).hexdigest(),
            size_bytes=len(content),
        )


def _archive(path: Path) -> Path:
    with ZipFile(path, "w") as archive:
        archive.writestr(
            "17100148.csv",
            "REF_DATE,GEO,DGUID,VALUE\n2025,Toronto,2021S0503535,7123456\n",
        )
        archive.writestr("17100148_MetaData.csv", "metadata")
    return path


def test_replay_is_skipped_and_does_not_duplicate_objects(tmp_path: Path) -> None:
    source = _archive(tmp_path / "source.zip")
    landing = tmp_path / "landing"
    store = LocalLandingStore(landing)
    client = cast(StatsCanClient, FakeStatsCanClient(source))
    timestamp = datetime(2026, 8, 13, 16, 0, tzinfo=UTC)

    first = acquire_dataset(
        DATASETS[1], client=client, store=store, work_dir=tmp_path / "run1", now=timestamp
    )
    second = acquire_dataset(
        DATASETS[1], client=client, store=store, work_dir=tmp_path / "run2", now=timestamp
    )

    assert first.outcome == "CREATED"
    assert second.outcome == "SKIPPED"
    objects = sorted(
        path.relative_to(landing).as_posix()
        for path in landing.rglob("*")
        if path.is_file()
    )
    assert len(objects) == 4
    assert any(path.endswith("_READY.csv") for path in objects)
    assert objects[-1].endswith("source.zip")

    ready_rows = list(csv.DictReader(io.StringIO(store.read_bytes(first.ready_path).decode())))
    assert len(ready_rows) == 1
    ready = ready_rows[0]
    assert ready["table_id"] == "17-10-0148-01"
    assert ready["batch_id"] == first.batch_id
    assert ready["source_last_modified_utc"] == "2026-01-14T13:30:47+00:00"
    assert ready["ingested_at_utc"] == "2026-08-13T16:00:00+00:00"
    assert ready["source_record_count"] == "1"
    assert ready["data_path"].endswith(f"batch_id={first.batch_id}/data.csv")
    assert ready["manifest_path"] == first.manifest_path
    assert len(ready["source_archive_sha256"]) == 64
    assert len(ready["data_csv_sha256"]) == 64
