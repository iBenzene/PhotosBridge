# tests/test_sync.py

from unittest.mock import Mock

import pytest

from photos_bridge_toolkit import (
    AssetPage,
    BridgeError,
    ToolkitStore,
    cache_thumbnails,
    sync_assets,
)
from test_store import asset


def test_sync_and_cache_resume_after_failure(tmp_path) -> None:
    client = Mock()
    client.iter_assets.return_value = iter(
        [
            AssetPage("snapshot", (asset("a"),), "next"),
            AssetPage("snapshot", (asset("b"),), None),
        ]
    )
    client.get_thumbnail.side_effect = [
        (b"first", "image/jpeg"),
        BridgeError("OFFLINE"),
    ]
    with ToolkitStore(tmp_path) as store:
        assert sync_assets(client, store, "device") == 2
        client.iter_assets.assert_called_once_with("device", limit=500)
        with pytest.raises(BridgeError):
            cache_thumbnails(client, store, "device", ["a", "b"])
        assert store.thumbnail_path("device", "a").read_bytes() == b"first"
        client.get_thumbnail.reset_mock(side_effect=True)
        client.get_thumbnail.return_value = (b"second", "image/jpeg")
        assert cache_thumbnails(client, store, "device", ["a", "b"]) == 1
        assert client.get_thumbnail.call_args.args == ("device", "b")
        assert cache_thumbnails(client, store, "device", ["a"], refresh=True) == 1
        assert store.thumbnail_path("device", "a").read_bytes() == b"second"


def test_sync_failure_retains_completed_pages_and_existing_records(tmp_path) -> None:
    def pages(*args, **kwargs):
        yield AssetPage("snapshot", (asset("new"),), "next")
        raise BridgeError("OFFLINE")

    client = Mock()
    client.iter_assets.side_effect = pages
    with ToolkitStore(tmp_path) as store:
        store.upsert_assets("device", [asset("old")])
        with pytest.raises(BridgeError):
            sync_assets(client, store, "device")
        assert {item.id for item in store.load_assets("device")} == {"old", "new"}
