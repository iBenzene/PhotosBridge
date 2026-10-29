# src/photos_bridge_toolkit/models.py

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

import numpy as np
from numpy.typing import NDArray


def parse_datetime(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


@dataclass(frozen=True, slots=True)
class Asset:
    """单张照片或视频资产的基础元数据模型"""

    id: str
    kind: str
    subtype: str | None
    created_at: datetime | None
    modified_at: datetime | None
    pixel_width: int
    pixel_height: int
    duration: float
    is_favorite: bool
    is_hidden: bool
    has_location: bool

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> Asset:
        return cls(
            id=str(payload["id"]),
            kind=str(payload["kind"]),
            subtype=str(payload["subtype"])
            if payload.get("subtype") is not None
            else None,
            created_at=parse_datetime(payload.get("created_at")),
            modified_at=parse_datetime(payload.get("modified_at")),
            pixel_width=int(payload.get("pixel_width", 0)),
            pixel_height=int(payload.get("pixel_height", 0)),
            duration=float(payload.get("duration", 0)),
            is_favorite=bool(payload.get("is_favorite", False)),
            is_hidden=bool(payload.get("is_hidden", False)),
            has_location=bool(payload.get("has_location", False)),
        )


@dataclass(frozen=True, slots=True)
class AssetPage:
    """照片资产元数据分页快照模型"""

    snapshot_id: str
    items: tuple[Asset, ...]
    next_cursor: str | None

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> AssetPage:
        return cls(
            snapshot_id=str(payload["snapshot_id"]),
            items=tuple(Asset.from_payload(item) for item in payload.get("items", [])),
            next_cursor=str(payload["next_cursor"])
            if payload.get("next_cursor") is not None
            else None,
        )


@dataclass(frozen=True, slots=True)
class Album:
    """相册元数据模型"""

    id: str
    title: str
    asset_count: int
    is_writable: bool

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> Album:
        return cls(
            id=str(payload["id"]),
            title=str(payload["title"]),
            asset_count=int(payload.get("asset_count", 0)),
            is_writable=bool(payload.get("is_writable", False)),
        )


@dataclass(frozen=True, slots=True)
class Embedding:
    """照片特征向量嵌入数据模型"""

    asset_id: str
    vector: NDArray[np.float32]


@dataclass(frozen=True, slots=True)
class VectorMatch:
    """向量余弦相似度检索匹配结果"""

    asset_id: str
    score: float
    query_index: int


@dataclass(frozen=True, slots=True)
class HashMatch:
    """感知哈希汉明距离匹配结果"""

    reference_asset_id: str
    asset_id: str
    distance: int


@dataclass(frozen=True, slots=True)
class TemporalMatch:
    """时间窗口邻近照片匹配结果"""

    reference_asset_id: str
    asset_id: str
    seconds_apart: float
