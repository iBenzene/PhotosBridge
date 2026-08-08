"""
@file paths.py
@description Retriever-owned runtime path resolution with an explicit environment override.
@author iBenzene
"""

from __future__ import annotations

import os
from pathlib import Path


def default_data_directory(environment: dict[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    configured = values.get("PHOTOS_BRIDGE_RETRIEVER_DATA_DIR")
    if configured:
        return Path(configured).expanduser().resolve()
    return Path(__file__).resolve().parents[2] / "data"
