"""Immutable object stores for local tests and ADLS Gen2 landing."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import BinaryIO, Protocol

from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.filedatalake import DataLakeServiceClient, FileSystemClient


class ObjectIntegrityError(RuntimeError):
    """Raised when an existing immutable object differs from expected bytes."""


class LandingStore(Protocol):
    def exists(self, path: str) -> bool: ...

    def read_bytes(self, path: str) -> bytes: ...

    def put_file(self, path: str, source: Path, sha256: str) -> bool: ...

    def put_bytes(self, path: str, content: bytes, sha256: str) -> bool: ...


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


class LocalLandingStore:
    """Filesystem implementation with the same no-overwrite semantics as ADLS."""

    def __init__(self, root: Path) -> None:
        self._root = root.resolve()

    def _resolve(self, path: str) -> Path:
        resolved = (self._root / Path(path)).resolve()
        if self._root != resolved and self._root not in resolved.parents:
            raise ValueError(f"Object path escapes landing root: {path}")
        return resolved

    def exists(self, path: str) -> bool:
        return self._resolve(path).is_file()

    def read_bytes(self, path: str) -> bytes:
        return self._resolve(path).read_bytes()

    def put_file(self, path: str, source: Path, sha256: str) -> bool:
        target = self._resolve(path)
        if target.exists():
            self._verify(target, sha256)
            return False
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            with source.open("rb") as input_file, target.open("xb") as output_file:
                for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
                    output_file.write(chunk)
        except FileExistsError:
            self._verify(target, sha256)
            return False
        self._verify(target, sha256)
        return True

    def put_bytes(self, path: str, content: bytes, sha256: str) -> bool:
        target = self._resolve(path)
        if target.exists():
            self._verify(target, sha256)
            return False
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            with target.open("xb") as output_file:
                output_file.write(content)
        except FileExistsError:
            self._verify(target, sha256)
            return False
        self._verify(target, sha256)
        return True

    @staticmethod
    def _verify(path: Path, expected_sha256: str) -> None:
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise ObjectIntegrityError(
                f"Immutable object differs at {path}: expected {expected_sha256}, got {actual}"
            )


class AzureDataLakeLandingStore:
    """ADLS Gen2 implementation authenticated with workload identity by default."""

    def __init__(self, account_url: str, file_system: str) -> None:
        credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
        service = DataLakeServiceClient(account_url=account_url, credential=credential)
        self._file_system: FileSystemClient = service.get_file_system_client(file_system)

    def _client(self, path: str):  # type: ignore[no-untyped-def]
        return self._file_system.get_file_client(path)

    def exists(self, path: str) -> bool:
        try:
            self._client(path).get_file_properties()
            return True
        except ResourceNotFoundError:
            return False

    def read_bytes(self, path: str) -> bytes:
        return bytes(self._client(path).download_file().readall())

    def put_file(self, path: str, source: Path, sha256: str) -> bool:
        with source.open("rb") as content:
            return self._put(path, content, sha256, source.stat().st_size)

    def put_bytes(self, path: str, content: bytes, sha256: str) -> bool:
        return self._put(path, content, sha256, len(content))

    def _put(
        self,
        path: str,
        content: bytes | BinaryIO,
        sha256: str,
        size_bytes: int,
    ) -> bool:
        client = self._client(path)
        try:
            client.upload_data(
                content,
                overwrite=False,
                length=size_bytes,
                metadata={"sha256": sha256},
            )
            return True
        except ResourceExistsError:
            properties = client.get_file_properties()
            existing_hash = (properties.metadata or {}).get("sha256")
            if properties.size != size_bytes or existing_hash != sha256:
                raise ObjectIntegrityError(
                    f"Immutable ADLS object differs at {path}: "
                    f"expected size/hash {size_bytes}/{sha256}, "
                    f"found {properties.size}/{existing_hash}"
                ) from None
            return False
