"""
@file __init__.py
@description Public retrieval primitives exposed to private Photos Bridge workflows.
@author iBenzene
"""

from .bridge import BridgeClient, BridgeError
from .models import (
    Album,
    Asset,
    AssetPage,
    Embedding,
    HashMatch,
    TemporalMatch,
    VectorMatch,
)
from .paths import default_data_directory
from .search import cosine_search, perceptual_hash_search, temporal_neighbors
from .store import RetrieverStore

__all__ = [
    "Album",
    "Asset",
    "AssetPage",
    "BridgeClient",
    "BridgeError",
    "Embedding",
    "HashMatch",
    "RetrieverStore",
    "TemporalMatch",
    "VectorMatch",
    "cosine_search",
    "default_data_directory",
    "perceptual_hash_search",
    "temporal_neighbors",
]
