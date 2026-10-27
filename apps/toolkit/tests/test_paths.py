# tests/test_paths.py

from pathlib import Path

from photos_bridge_toolkit import default_data_directory


def test_defaults_to_toolkit_owned_data_directory() -> None:
    path = default_data_directory({})

    assert path.name == "data"
    assert path.parent.name == "toolkit"


def test_environment_override_is_resolved(tmp_path: Path) -> None:
    configured = tmp_path / "custom" / ".." / "retrieval-data"

    assert (
        default_data_directory({"PHOTOS_BRIDGE_TOOLKIT_DATA_DIR": str(configured)})
        == configured.resolve()
    )
