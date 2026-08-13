import hashlib
from types import SimpleNamespace
from typing import Any, cast

import pytest
from azure.core.exceptions import ResourceExistsError

from regional_intelligence.storage import AzureDataLakeLandingStore, ObjectIntegrityError


class FakeDownload:
    def __init__(self, content: bytes) -> None:
        self._content = content

    def chunks(self):  # type: ignore[no-untyped-def]
        midpoint = len(self._content) // 2
        return iter((self._content[:midpoint], self._content[midpoint:]))


class FakeFileClient:
    def __init__(
        self,
        *,
        content: bytes | None = None,
        metadata: dict[str, str] | None = None,
    ) -> None:
        self.content = content
        self.metadata = metadata or {}
        self.upload_kwargs: dict[str, Any] | None = None

    def upload_data(self, content: bytes, **kwargs: Any) -> None:
        self.upload_kwargs = kwargs
        if self.content is not None:
            raise ResourceExistsError("already exists")
        self.content = content

    def set_metadata(self, metadata: dict[str, str]) -> None:
        self.metadata = metadata

    def get_file_properties(self):  # type: ignore[no-untyped-def]
        return SimpleNamespace(size=len(self.content or b""), metadata=self.metadata)

    def download_file(self) -> FakeDownload:
        return FakeDownload(self.content or b"")


def _store_with_client(client: FakeFileClient) -> AzureDataLakeLandingStore:
    store = object.__new__(AzureDataLakeLandingStore)
    store._client = cast(Any, lambda _path: client)  # type: ignore[method-assign]
    return store


def test_new_adls_object_is_uploaded_without_overwrite_and_then_tagged() -> None:
    content = b"immutable"
    expected_hash = hashlib.sha256(content).hexdigest()
    client = FakeFileClient()

    created = _store_with_client(client).put_bytes("data.csv", content, expected_hash)

    assert created is True
    assert client.content == content
    assert client.upload_kwargs == {"overwrite": False, "length": len(content)}
    assert client.metadata == {"sha256": expected_hash}


def test_existing_object_without_metadata_is_verified_and_healed() -> None:
    content = b"immutable"
    expected_hash = hashlib.sha256(content).hexdigest()
    client = FakeFileClient(content=content)

    created = _store_with_client(client).put_bytes("data.csv", content, expected_hash)

    assert created is False
    assert client.metadata == {"sha256": expected_hash}


def test_existing_object_with_different_bytes_is_rejected() -> None:
    expected = b"expected"
    client = FakeFileClient(content=b"different")

    with pytest.raises(ObjectIntegrityError, match="Immutable ADLS object differs"):
        _store_with_client(client).put_bytes(
            "data.csv", expected, hashlib.sha256(expected).hexdigest()
        )
