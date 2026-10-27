# src/photos_bridge_toolkit/search.py

from __future__ import annotations

from bisect import bisect_left, bisect_right
from collections.abc import Iterable, Mapping, Sequence
from datetime import timedelta

import numpy as np

from .models import Asset, Embedding, HashMatch, TemporalMatch, VectorMatch


def cosine_search(
    queries: np.ndarray,
    candidates: Sequence[Embedding],
    *,
    top_k: int,
    exclude_asset_ids: Iterable[str] = (),
    batch_size: int = 8192,
) -> tuple[VectorMatch, ...]:
    """基于行归一化矩阵点积执行批量余弦相似度检索。

    queries: 形状为 (N, D) 或 (D,) 的查询特征向量矩阵。
    candidates: 待检索的候选特征嵌入集合。
    top_k: 返回的相似度最高的结果数量上限。
    exclude_asset_ids: 排除在结果之外的照片唯一标识集合。
    batch_size: 批处理计算的大小, 避免候选集过大时内存溢出。
    """
    if top_k < 1 or batch_size < 1:
        raise ValueError("top_k and batch_size must be positive")
    query_matrix = np.asarray(queries, dtype=np.float32)
    if query_matrix.ndim == 1:
        query_matrix = query_matrix[None, :]
    if (
        query_matrix.ndim != 2
        or query_matrix.shape[0] == 0
        or query_matrix.shape[1] == 0
    ):
        raise ValueError("queries must contain at least one vector")
    query_matrix = _normalize_rows(query_matrix)
    excluded = set(exclude_asset_ids)
    matches: list[VectorMatch] = []
    for start in range(0, len(candidates), batch_size):
        batch = [
            candidate
            for candidate in candidates[start : start + batch_size]
            if candidate.asset_id not in excluded
        ]
        if not batch:
            continue
        matrix = np.stack([candidate.vector for candidate in batch]).astype(
            np.float32, copy=False
        )
        if matrix.shape[1] != query_matrix.shape[1]:
            raise ValueError("query and candidate dimensions differ")
        # 归一化后执行矩阵相乘, 计算当前批次与所有查询项的余弦相似度。
        scores = _normalize_rows(matrix) @ query_matrix.T
        best_queries = np.argmax(scores, axis=1)
        best_scores = scores[np.arange(scores.shape[0]), best_queries]
        matches.extend(
            VectorMatch(candidate.asset_id, float(score), int(query_index))
            for candidate, score, query_index in zip(
                batch, best_scores, best_queries, strict=True
            )
        )
    matches.sort(key=lambda match: (-match.score, match.asset_id))
    return tuple(matches[:top_k])


def perceptual_hash_search(
    reference_hashes: Mapping[str, int],
    candidate_hashes: Mapping[str, int],
    *,
    max_distance: int,
    exclude_asset_ids: Iterable[str] = (),
) -> tuple[HashMatch, ...]:
    """通过汉明距离比对感知哈希, 检索视觉高度相似或重复的照片。

    reference_hashes: 基准照片标识与哈希数值的映射。
    candidate_hashes: 候选照片标识与哈希数值的映射。
    max_distance: 允许的最大汉明距离阈值, 越小代表视觉差异越小。
    exclude_asset_ids: 排除在匹配结果之外的照片唯一标识集合。
    """
    if max_distance < 0:
        raise ValueError("max_distance cannot be negative")
    excluded = set(exclude_asset_ids)
    matches = [
        HashMatch(reference_id, asset_id, (reference_hash ^ candidate_hash).bit_count())
        for reference_id, reference_hash in reference_hashes.items()
        for asset_id, candidate_hash in candidate_hashes.items()
        if asset_id not in excluded
        and asset_id != reference_id
        and (reference_hash ^ candidate_hash).bit_count() <= max_distance
    ]
    matches.sort(
        key=lambda match: (match.distance, match.reference_asset_id, match.asset_id)
    )
    return tuple(matches)


def temporal_neighbors(
    assets: Sequence[Asset],
    reference_asset_ids: Iterable[str],
    *,
    maximum_gap: timedelta,
    maximum_per_reference: int = 20,
) -> tuple[TemporalMatch, ...]:
    """检索给定基准照片在指定时间窗口内的时间邻近资产。

    assets: 包含拍摄时间的资产序列。
    reference_asset_ids: 作为基准锚点的照片标识列表。
    maximum_gap: 允许的最大时间偏差 (timedelta)。
    maximum_per_reference: 每个基准照片最多返回的邻近照片数量。
    """
    if maximum_gap.total_seconds() < 0 or maximum_per_reference < 1:
        raise ValueError(
            "maximum_gap must be non-negative and maximum_per_reference must be positive"
        )
    dated = sorted(
        (
            (asset.created_at.timestamp(), asset.id)
            for asset in assets
            if asset.created_at is not None
        ),
        key=lambda item: (item[0], item[1]),
    )
    timestamps = [item[0] for item in dated]
    by_id = {asset_id: timestamp for timestamp, asset_id in dated}
    gap = maximum_gap.total_seconds()
    matches: list[TemporalMatch] = []
    for reference_id in sorted(set(reference_asset_ids)):
        reference_time = by_id.get(reference_id)
        if reference_time is None:
            continue
        # 使用二分查找快速切片落在时间窗口 [t - gap, t + gap] 内的目标资产。
        start = bisect_left(timestamps, reference_time - gap)
        end = bisect_right(timestamps, reference_time + gap)
        nearby = [
            TemporalMatch(reference_id, asset_id, abs(timestamp - reference_time))
            for timestamp, asset_id in dated[start:end]
            if asset_id != reference_id
        ]
        nearby.sort(key=lambda match: (match.seconds_apart, match.asset_id))
        matches.extend(nearby[:maximum_per_reference])
    return tuple(matches)


def _normalize_rows(matrix: np.ndarray) -> np.ndarray:
    """对矩阵执行 L2 行归一化处理, 确保每个向量模长为 1。"""
    if not np.all(np.isfinite(matrix)):
        raise ValueError("vectors must be finite")
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    if np.any(norms == 0):
        raise ValueError("vectors cannot be zero")
    return matrix / norms
