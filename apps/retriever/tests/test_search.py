"""
@file test_search.py
@description Tests for model-agnostic vector, perceptual-hash, and temporal search primitives.
@author iBenzene
"""

from datetime import datetime, timedelta, timezone

import numpy as np
import pytest

from photos_bridge_retriever import (
    Asset,
    Embedding,
    cosine_search,
    perceptual_hash_search,
    temporal_neighbors,
)


def test_cosine_search_uses_best_query_exclusions_and_stable_ordering() -> None:
    candidates = (
        Embedding("a", np.array([1.0, 0.0], dtype=np.float32)),
        Embedding("b", np.array([0.0, 1.0], dtype=np.float32)),
        Embedding("c", np.array([0.7, 0.7], dtype=np.float32)),
    )

    matches = cosine_search(
        np.array([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32),
        candidates,
        top_k=3,
        exclude_asset_ids={"b"},
        batch_size=1,
    )

    assert [match.asset_id for match in matches] == ["a", "c"]
    assert matches[0].query_index == 0
    assert matches[0].score == pytest.approx(1.0)


def test_cosine_search_rejects_incompatible_dimensions() -> None:
    with pytest.raises(ValueError, match="dimensions"):
        cosine_search(
            np.array([1.0, 0.0], dtype=np.float32),
            (Embedding("a", np.array([1.0, 0.0, 0.0], dtype=np.float32)),),
            top_k=1,
        )


def test_perceptual_hash_search_returns_raw_hamming_evidence() -> None:
    matches = perceptual_hash_search(
        {"reference": 0b0000},
        {"same": 0b0000, "near": 0b0011, "far": 0b1111},
        max_distance=2,
        exclude_asset_ids={"same"},
    )

    assert [(match.asset_id, match.distance) for match in matches] == [("near", 2)]


def test_temporal_neighbors_are_limited_per_reference() -> None:
    origin = datetime(2026, 8, 8, 12, 0, tzinfo=timezone.utc)
    assets = (
        asset("reference", origin),
        asset("near-1", origin - timedelta(minutes=2)),
        asset("near-2", origin + timedelta(minutes=3)),
        asset("far", origin + timedelta(hours=2)),
    )

    matches = temporal_neighbors(
        assets,
        ["reference"],
        maximum_gap=timedelta(minutes=10),
        maximum_per_reference=1,
    )

    assert len(matches) == 1
    assert matches[0].asset_id == "near-1"
    assert matches[0].seconds_apart == 120


def asset(asset_id: str, created_at: datetime) -> Asset:
    return Asset(
        id=asset_id,
        kind="image",
        subtype=None,
        created_at=created_at,
        modified_at=None,
        pixel_width=100,
        pixel_height=100,
        duration=0,
        is_favorite=False,
        is_hidden=False,
        has_location=False,
    )
