"""Safe extraction and validation for Statistics Canada full-table archives."""

from __future__ import annotations

import csv
import hashlib
import shutil
from dataclasses import dataclass
from pathlib import Path
from zipfile import BadZipFile, ZipFile


class ArchiveValidationError(RuntimeError):
    """Raised when a source archive is not the expected full-table package."""


@dataclass(frozen=True, slots=True)
class PreparedCsv:
    path: Path
    sha256: str
    size_bytes: int
    record_count: int
    columns: tuple[str, ...]


REQUIRED_COLUMNS = frozenset({"REF_DATE", "GEO", "DGUID", "VALUE"})


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_data_csv(archive_path: Path, destination: Path) -> PreparedCsv:
    """Extract exactly one non-metadata CSV to a caller-controlled safe path."""

    try:
        with ZipFile(archive_path) as archive:
            candidates = [
                member
                for member in archive.infolist()
                if not member.is_dir()
                and member.filename.lower().endswith(".csv")
                and "metadata" not in member.filename.lower()
            ]
            if len(candidates) != 1:
                names = [member.filename for member in candidates]
                raise ArchiveValidationError(
                    f"Expected one data CSV in {archive_path.name}; found {names!r}"
                )

            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(candidates[0]) as source, destination.open("wb") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)
    except BadZipFile as error:
        raise ArchiveValidationError(f"Invalid ZIP archive: {archive_path}") from error

    size_bytes = destination.stat().st_size
    if size_bytes == 0:
        raise ArchiveValidationError(f"Extracted CSV is empty: {destination}")

    with destination.open("r", encoding="utf-8-sig", newline="") as source:
        reader = csv.reader(source)
        try:
            columns = tuple(next(reader))
        except StopIteration as error:
            raise ArchiveValidationError(f"CSV has no header: {destination}") from error
        missing = REQUIRED_COLUMNS.difference(columns)
        if missing:
            raise ArchiveValidationError(
                f"CSV is missing required columns {sorted(missing)!r}: {destination}"
            )
        record_count = sum(1 for _ in reader)

    if record_count == 0:
        raise ArchiveValidationError(f"CSV has no data records: {destination}")

    return PreparedCsv(
        path=destination,
        sha256=_sha256(destination),
        size_bytes=size_bytes,
        record_count=record_count,
        columns=columns,
    )

