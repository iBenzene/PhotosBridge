"""
@file test_store.py
@description Tests for the retriever's local catalog, object cache, embeddings, and hashes.
@author iBenzene
"""

from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pytest

from photos_bridge_retriever import Asset, RetrieverStore


def test_persists_assets_and_replaces_album_membership(tmp_path: Path) -> None:
    with RetrieverStore(tmp_path) as store:
        assert store.upsert_assets("device", [asset("asset-1"), asset("asset-2")]) == 2
        store.replace_album_assets("device", "album", ["asset-2", "asset-1", "asset-2"])
        store.replace_album_assets("device", "album", ["asset-2"])

        assert [item.id for item in store.load_assets("device")] == [
            "asset-1",
            "asset-2",
        ]
        assert store.load_album_assets("device", "album") == ("asset-2",)


def test_content_addressed_thumbnail_cache_deduplicates_bytes(tmp_path: Path) -> None:
    with RetrieverStore(tmp_path) as store:
        store.upsert_assets("device", [asset("asset-1"), asset("asset-2")])

        first = store.store_thumbnail("device", "asset-1", b"same-jpeg", "image/jpeg")
        second = store.store_thumbnail("device", "asset-2", b"same-jpeg", "image/jpeg")

        assert first == second
        assert store.thumbnail_path("device", "asset-1") == store.thumbnail_path(
            "device", "asset-2"
        )
        assert store.thumbnail_path("device", "asset-1").read_bytes() == b"same-jpeg"
        assert store.object_path(first).parent.name == first[:2]
        assert (
            store.connection.execute("SELECT COUNT(*) FROM objects").fetchone()[0] == 1
        )


def test_thumbnail_requires_catalogued_asset(tmp_path: Path) -> None:
    with RetrieverStore(tmp_path) as store, pytest.raises(KeyError):
        store.store_thumbnail("device", "missing", b"jpeg", "image/jpeg")


def test_embeddings_are_normalized_versioned_and_round_trip(tmp_path: Path) -> None:
    with RetrieverStore(tmp_path) as store:
        store.put_embedding(
            "device", "model-a", "asset", np.array([3.0, 4.0], dtype=np.float32)
        )
        store.put_embedding(
            "device", "model-b", "asset", np.array([1.0, 0.0], dtype=np.float32)
        )

        model_a = store.load_embeddings("device", "model-a")

        assert len(model_a) == 1
        assert model_a[0].asset_id == "asset"
        assert model_a[0].vector == pytest.approx(
            np.array([0.6, 0.8], dtype=np.float32), abs=5e-4
        )
        assert len(store.load_embeddings("device", "model-b")) == 1


def test_perceptual_hashes_are_algorithm_scoped(tmp_path: Path) -> None:
    with RetrieverStore(tmp_path) as store:
        store.put_hash("device", "phash-64", "asset", 0xFF, 64)
        store.put_hash("device", "dhash-64", "asset", 0xAA, 64)

        assert store.load_hashes("device", "phash-64") == {"asset": 0xFF}
        assert store.load_hashes("device", "dhash-64") == {"asset": 0xAA}


def asset(asset_id: str) -> Asset:
    return Asset(
        id=asset_id,
        kind="image",
        subtype=None,
        created_at=datetime(2026, 8, 8, 12, 0, tzinfo=timezone.utc),
        modified_at=None,
        pixel_width=100,
        pixel_height=200,
        duration=0,
        is_favorite=False,
        is_hidden=False,
        has_location=False,
    )
