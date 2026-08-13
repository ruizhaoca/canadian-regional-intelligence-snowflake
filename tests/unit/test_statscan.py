from pathlib import Path

import httpx
import respx

from regional_intelligence.statscan import StatsCanClient


@respx.mock
def test_resolve_download_url() -> None:
    route = respx.get(
        "https://www150.statcan.gc.ca/t1/wds/rest/"
        "getFullTableDownloadCSV/14100461/en"
    ).mock(
        return_value=httpx.Response(
            200,
            json={
                "status": "SUCCESS",
                "object": "https://www150.statcan.gc.ca/n1/tbl/csv/14100461-eng.zip",
            },
        )
    )

    with StatsCanClient() as client:
        result = client.resolve_download_url("14100461")

    assert route.called
    assert result.endswith("14100461-eng.zip")


@respx.mock
def test_download_calculates_checksum(tmp_path: Path) -> None:
    source_url = "https://example.test/table.zip"
    respx.get(source_url).mock(
        return_value=httpx.Response(
            200,
            content=b"test-zip-content",
            headers={"Last-Modified": "Wed, 12 Aug 2026 12:00:00 GMT"},
        )
    )

    with StatsCanClient() as client:
        result = client.download(source_url, tmp_path / "table.zip")

    assert result.size_bytes == 16
    assert result.source_last_modified == "Wed, 12 Aug 2026 12:00:00 GMT"
    assert result.sha256 == "62e90eb1d8f5e3280686e141ea7351e2d531f2d0cd59393abfd8d800e4eca61f"
