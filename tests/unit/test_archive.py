import csv
from pathlib import Path
from zipfile import ZipFile

import pytest

from regional_intelligence.archive import ArchiveValidationError, extract_data_csv


def _write_archive(path: Path, *, include_value: bool = True) -> None:
    columns = ["REF_DATE", "GEO", "DGUID"]
    if include_value:
        columns.append("VALUE")
    data_path = path.parent / "source.csv"
    with data_path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(columns)
        writer.writerow(["2025", "Toronto", "2021S0503535", "1"][: len(columns)])
    with ZipFile(path, "w") as archive:
        archive.write(data_path, "14100461.csv")
        archive.writestr("14100461_MetaData.csv", "metadata")


def test_extracts_only_data_csv_and_counts_records(tmp_path: Path) -> None:
    archive = tmp_path / "source.zip"
    _write_archive(archive)

    result = extract_data_csv(archive, tmp_path / "data.csv")

    assert result.record_count == 1
    assert result.columns == ("REF_DATE", "GEO", "DGUID", "VALUE")
    assert result.size_bytes > 0


def test_rejects_missing_required_columns(tmp_path: Path) -> None:
    archive = tmp_path / "source.zip"
    _write_archive(archive, include_value=False)

    with pytest.raises(ArchiveValidationError, match="VALUE"):
        extract_data_csv(archive, tmp_path / "data.csv")

