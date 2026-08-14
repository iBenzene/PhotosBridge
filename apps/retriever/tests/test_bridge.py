"""
@file test_bridge.py
@description Tests for the retriever's read-only Photos Bridge HTTP client.
@author iBenzene
"""

from __future__ import annotations

import json
from urllib.request import Request

import pytest

from photos_bridge_retriever import BridgeClient


class StubBridgeClient(BridgeClient):
    def __init__(self, responses: list[tuple[bytes, str]]) -> None:
        super().__init__("http://bridge.test", "read-key")
        self.responses = responses
        self.requests: list[Request] = []

    def _send(self, request: Request) -> tuple[bytes, str]:
        self.requests.append(request)
        return self.responses.pop(0)


def encoded(payload: object) -> tuple[bytes, str]:
    return json.dumps(payload).encode(), "application/json"


def test_pages_assets_with_stable_snapshot_and_opaque_identifiers() -> None:
    client = StubBridgeClient(
        [
            encoded(
                {
                    "snapshot_id": "snapshot-1",
                    "items": [asset_payload("asset/one")],
                    "next_cursor": "1",
                }
            ),
            encoded(
                {
                    "snapshot_id": "snapshot-1",
                    "items": [asset_payload("asset two")],
                    "next_cursor": None,
                }
            ),
        ]
    )

    pages = tuple(client.iter_assets("device/one", limit=1))

    assert [page.items[0].id for page in pages] == ["asset/one", "asset two"]
    assert "/device%2Fone/assets?limit=1" in client.requests[0].full_url
    assert "snapshot_id=snapshot-1" in client.requests[1].full_url
    assert "cursor=1" in client.requests[1].full_url
    assert client.requests[0].get_header("Authorization") == "Bearer read-key"


def test_reads_albums_members_and_thumbnail_without_write_methods() -> None:
    client = StubBridgeClient(
        [
            encoded(
                {
                    "albums": [
                        {
                            "id": "album/1",
                            "title": "Reference",
                            "asset_count": 2,
                            "is_writable": True,
                        }
                    ]
                }
            ),
            encoded({"asset_ids": ["asset-1", "asset-2"]}),
            (b"jpeg", "image/jpeg; charset=binary"),
        ]
    )

    albums = client.list_albums("device-1")
    members = client.list_album_assets("device-1", albums[0].id)
    thumbnail, media_type = client.get_thumbnail(
        "device-1", "asset/1", max_dimension=518
    )

    assert albums[0].title == "Reference"
    assert members == ("asset-1", "asset-2")
    assert thumbnail == b"jpeg"
    assert media_type == "image/jpeg"
    assert "/album%2F1/assets" in client.requests[1].full_url
    assert "/asset%2F1/thumbnail?max_dimension=518&content_mode=fit" in client.requests[2].full_url
    assert not hasattr(client, "create_plan")
    assert not hasattr(client, "deliver_plan")


def test_thumbnail_can_request_fill_and_rejects_unknown_content_mode() -> None:
    client = StubBridgeClient([(b"jpeg", "image/jpeg")])

    client.get_thumbnail("device-1", "asset-1", content_mode="fill")

    assert "/asset-1/thumbnail?max_dimension=518&content_mode=fill" in client.requests[0].full_url
    with pytest.raises(ValueError, match="content_mode"):
        client.get_thumbnail("device-1", "asset-1", content_mode="stretch")  # type: ignore[arg-type]


@pytest.mark.parametrize("limit", [0, 501])
def test_rejects_invalid_page_size(limit: int) -> None:
    with pytest.raises(ValueError):
        StubBridgeClient([]).list_assets("device", limit=limit)


def asset_payload(asset_id: str) -> dict[str, object]:
    return {
        "id": asset_id,
        "kind": "image",
        "subtype": None,
        "created_at": "2026-08-08T12:00:00Z",
        "modified_at": None,
        "pixel_width": 100,
        "pixel_height": 200,
        "duration": 0,
        "is_favorite": False,
        "is_hidden": False,
        "has_location": False,
    }
