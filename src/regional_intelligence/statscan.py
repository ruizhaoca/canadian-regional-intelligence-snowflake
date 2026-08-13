"""Client for Statistics Canada's official Web Data Service."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential


class StatsCanError(RuntimeError):
    """Raised when WDS returns an invalid or unsuccessful response."""


@dataclass(frozen=True, slots=True)
class DownloadedFile:
    path: Path
    source_url: str
    source_last_modified: str | None
    sha256: str
    size_bytes: int


class StatsCanClient:
    """Resolve and stream full-table CSV ZIP archives."""

    def __init__(
        self,
        *,
        base_url: str = "https://www150.statcan.gc.ca/t1/wds/rest",
        timeout_seconds: float = 120.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = httpx.Client(
            timeout=httpx.Timeout(timeout_seconds, connect=20.0),
            follow_redirects=True,
            headers={"User-Agent": "canadian-regional-intelligence/0.1"},
        )

    def __enter__(self) -> StatsCanClient:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    @retry(
        retry=retry_if_exception_type((httpx.TransportError, httpx.TimeoutException)),
        stop=stop_after_attempt(4),
        wait=wait_exponential(multiplier=1, min=1, max=8),
        reraise=True,
    )
    def resolve_download_url(self, product_id: str) -> str:
        response = self._client.get(
            f"{self._base_url}/getFullTableDownloadCSV/{product_id}/en"
        )
        response.raise_for_status()
        payload: dict[str, Any] = response.json()
        if payload.get("status") != "SUCCESS" or not isinstance(payload.get("object"), str):
            raise StatsCanError(f"Unexpected WDS response for PID {product_id}: {payload!r}")
        return str(payload["object"])

    @retry(
        retry=retry_if_exception_type((httpx.TransportError, httpx.TimeoutException)),
        stop=stop_after_attempt(4),
        wait=wait_exponential(multiplier=1, min=1, max=8),
        reraise=True,
    )
    def download(self, source_url: str, destination: Path) -> DownloadedFile:
        destination.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        size_bytes = 0

        with self._client.stream("GET", source_url) as response:
            response.raise_for_status()
            source_last_modified = response.headers.get("last-modified")
            with destination.open("wb") as output:
                for chunk in response.iter_bytes():
                    if not chunk:
                        continue
                    output.write(chunk)
                    digest.update(chunk)
                    size_bytes += len(chunk)

        if size_bytes == 0:
            destination.unlink(missing_ok=True)
            raise StatsCanError(f"Statistics Canada returned an empty file: {source_url}")

        return DownloadedFile(
            path=destination,
            source_url=source_url,
            source_last_modified=source_last_modified,
            sha256=digest.hexdigest(),
            size_bytes=size_bytes,
        )

