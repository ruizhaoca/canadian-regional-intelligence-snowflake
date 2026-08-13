import hashlib
from types import SimpleNamespace
from typing import Any, cast

import pytest
from azure.core.exceptions import ResourceExistsError

from regional_intelligence.storage import AzureDataLakeLandingStore, ObjectIntegrityError


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

    def upload_blob(self, content: bytes, **kwargs: Any) -> None:
        self.upload_kwargs = kwargs
        if self.content is not None:
            raise ResourceExistsError("already exists")
        self.content = content
        self.metadata = kwargs.get("metadata", {})

    def get_blob_properties(self):  # type: ignore[no-untyped-def]
        return SimpleNamespace(size=len(self.content or b""), metadata=self.metadata)


def _store_with_client(client: FakeFileClient) -> AzureDataLakeLandingStore:
    store = object.__new__(AzureDataLakeLandingStore)
    store._client = cast(Any, lambda _path: client)  # type: ignore[method-assign]
    return store


def test_new_adls_object_is_atomically_uploaded_without_overwrite() -> None:
    content = b"immutable"
    expected_hash = hashlib.sha256(content).hexdigest()
    client = FakeFileClient()

    created = _store_with_client(client).put_bytes("data.csv", content, expected_hash)

    assert created is True
    assert client.content == content
    assert client.upload_kwargs == {
        "overwrite": False,
        "length": len(content),
        "metadata": {"sha256": expected_hash},
    }
    assert client.metadata == {"sha256": expected_hash}


def test_existing_object_with_matching_metadata_is_skipped() -> None:
    content = b"immutable"
    expected_hash = hashlib.sha256(content).hexdigest()
    client = FakeFileClient(content=content, metadata={"sha256": expected_hash})

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
