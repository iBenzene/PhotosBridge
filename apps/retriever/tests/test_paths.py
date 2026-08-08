"""
@file test_paths.py
@description Tests for retriever-owned default and overridden runtime data paths.
@author iBenzene
"""

from pathlib import Path

from photos_bridge_retriever import default_data_directory


def test_defaults_to_retriever_owned_data_directory() -> None:
    path = default_data_directory({})

    assert path.name == "data"
    assert path.parent.name == "retriever"


def test_environment_override_is_resolved(tmp_path: Path) -> None:
    configured = tmp_path / "custom" / ".." / "retrieval-data"

    assert (
        default_data_directory({"PHOTOS_BRIDGE_RETRIEVER_DATA_DIR": str(configured)})
        == configured.resolve()
    )
