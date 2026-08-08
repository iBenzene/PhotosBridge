"""
@file bridge.py
@description Read-only HTTP client for the public Photos Bridge Server library endpoints.
@author iBenzene
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any, Literal
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

from .models import Album, AssetPage

ThumbnailContentMode = Literal["fit", "fill"]


class BridgeError(RuntimeError):
    def __init__(
        self, code: str, status: int | None = None, details: object = None
    ) -> None:
        super().__init__(code)
        self.code = code
        self.status = status
        self.details = details


class BridgeClient:
    def __init__(self, base_url: str, api_key: str, timeout: float = 30.0) -> None:
        if not base_url.strip() or not api_key.strip():
            raise ValueError("base_url and api_key are required")
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def list_albums(self, device_id: str) -> tuple[Album, ...]:
        payload = self._get_json(f"/api/v1/devices/{self._segment(device_id)}/albums")
        return tuple(Album.from_payload(item) for item in payload.get("albums", []))

    def list_album_assets(self, device_id: str, album_id: str) -> tuple[str, ...]:
        payload = self._get_json(
            f"/api/v1/devices/{self._segment(device_id)}/albums/{self._segment(album_id)}/assets"
        )
        return tuple(str(asset_id) for asset_id in payload.get("asset_ids", []))

    def list_assets(
        self,
        device_id: str,
        *,
        snapshot_id: str | None = None,
        cursor: str | None = None,
        limit: int = 500,
    ) -> AssetPage:
        if not 1 <= limit <= 500:
            raise ValueError("limit must be between 1 and 500")
        query = {"limit": str(limit)}
        if snapshot_id is not None:
            query["snapshot_id"] = snapshot_id
        if cursor is not None:
            query["cursor"] = cursor
        path = f"/api/v1/devices/{self._segment(device_id)}/assets?{urlencode(query)}"
        return AssetPage.from_payload(self._get_json(path))

    def iter_assets(self, device_id: str, *, limit: int = 500) -> Iterator[AssetPage]:
        snapshot_id: str | None = None
        cursor: str | None = None
        while True:
            page = self.list_assets(
                device_id, snapshot_id=snapshot_id, cursor=cursor, limit=limit
            )
            yield page
            snapshot_id = page.snapshot_id
            cursor = page.next_cursor
            if cursor is None:
                return

    def get_thumbnail(
        self,
        device_id: str,
        asset_id: str,
        *,
        max_dimension: int = 518,
        content_mode: ThumbnailContentMode = "fit",
    ) -> tuple[bytes, str]:
        if not 1 <= max_dimension <= 1024:
            raise ValueError("max_dimension must be between 1 and 1024")
        if content_mode not in ("fit", "fill"):
            raise ValueError("content_mode must be 'fit' or 'fill'")
        path = (
            f"/api/v1/devices/{self._segment(device_id)}/assets/{self._segment(asset_id)}/thumbnail"
            f"?{urlencode({'max_dimension': str(max_dimension), 'content_mode': content_mode})}"
        )
        body, media_type = self._get(path)
        return body, media_type.split(";", 1)[0].strip() or "application/octet-stream"

    def _get_json(self, path: str) -> dict[str, Any]:
        body, _media_type = self._get(path)
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise BridgeError("INVALID_SERVER_RESPONSE") from error
        if not isinstance(payload, dict):
            raise BridgeError("INVALID_SERVER_RESPONSE")
        return payload

    def _get(self, path: str) -> tuple[bytes, str]:
        request = Request(
            f"{self.base_url}{path}",
            headers={
                "Accept": "application/json, image/*",
                "Authorization": f"Bearer {self.api_key}",
            },
            method="GET",
        )
        try:
            return self._send(request)
        except HTTPError as error:
            body = error.read()
            try:
                payload = json.loads(body)
                details = payload.get("error", {})
                code = str(details.get("code", "HTTP_ERROR"))
            except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
                details = body.decode("utf-8", errors="replace")
                code = "HTTP_ERROR"
            raise BridgeError(code, error.code, details) from error
        except URLError as error:
            raise BridgeError(
                "SERVER_UNREACHABLE", details=str(error.reason)
            ) from error

    def _send(self, request: Request) -> tuple[bytes, str]:
        with urlopen(request, timeout=self.timeout) as response:
            return response.read(), response.headers.get_content_type()

    @staticmethod
    def _segment(value: str) -> str:
        if not value:
            raise ValueError("path identifier cannot be empty")
        return quote(value, safe="")
