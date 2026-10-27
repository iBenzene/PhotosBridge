# src/photos_bridge_toolkit/__init__.py

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
from .store import ToolkitStore

__all__ = [
    "Album",
    "Asset",
    "AssetPage",
    "BridgeClient",
    "BridgeError",
    "Embedding",
    "HashMatch",
    "ToolkitStore",
    "TemporalMatch",
    "VectorMatch",
    "cosine_search",
    "default_data_directory",
    "perceptual_hash_search",
    "temporal_neighbors",
]
