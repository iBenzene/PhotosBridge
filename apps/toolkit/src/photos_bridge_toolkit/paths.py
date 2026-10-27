# src/photos_bridge_toolkit/paths.py

from __future__ import annotations

import os
from pathlib import Path


def default_data_directory(environment: dict[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    configured = values.get("PHOTOS_BRIDGE_TOOLKIT_DATA_DIR")
    if configured:
        return Path(configured).expanduser().resolve()
    return Path(__file__).resolve().parents[2] / "data"
