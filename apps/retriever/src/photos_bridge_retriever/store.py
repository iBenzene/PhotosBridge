"""
@file store.py
@description Retriever-owned SQLite catalog and content-addressed local object storage.
@author iBenzene
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
import tempfile
from collections.abc import Iterable
from pathlib import Path

import numpy as np

from .models import Asset, Embedding
from .paths import default_data_directory


SCHEMA_VERSION = 1


class RetrieverStore:
    def __init__(self, root: str | Path | None = None) -> None:
        self.root = (
            Path(root).resolve() if root is not None else default_data_directory()
        )
        self.state_directory = self.root / "state"
        self.object_directory = self.root / "cache" / "objects" / "sha256"
        self.state_directory.mkdir(parents=True, exist_ok=True)
        self.object_directory.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(self.state_directory / "catalog.sqlite")
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode = WAL")
        self.connection.execute("PRAGMA foreign_keys = ON")
        self.connection.execute("PRAGMA busy_timeout = 5000")
        self._migrate()

    def close(self) -> None:
        self.connection.close()

    def __enter__(self) -> RetrieverStore:
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def upsert_assets(self, device_id: str, assets: Iterable[Asset]) -> int:
        rows = [
            (
                device_id,
                asset.id,
                asset.kind,
                asset.subtype,
                self._date(asset.created_at),
                self._date(asset.modified_at),
                asset.pixel_width,
                asset.pixel_height,
                asset.duration,
                int(asset.is_favorite),
                int(asset.is_hidden),
                int(asset.has_location),
            )
            for asset in assets
        ]
        if not rows:
            return 0
        with self.connection:
            self.connection.executemany(
                """
                INSERT INTO assets (
                    device_id, asset_id, kind, subtype, created_at, modified_at,
                    pixel_width, pixel_height, duration, is_favorite, is_hidden, has_location
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id, asset_id) DO UPDATE SET
                    kind = excluded.kind,
                    subtype = excluded.subtype,
                    created_at = excluded.created_at,
                    modified_at = excluded.modified_at,
                    pixel_width = excluded.pixel_width,
                    pixel_height = excluded.pixel_height,
                    duration = excluded.duration,
                    is_favorite = excluded.is_favorite,
                    is_hidden = excluded.is_hidden,
                    has_location = excluded.has_location
                """,
                rows,
            )
        return len(rows)

    def load_assets(self, device_id: str) -> tuple[Asset, ...]:
        rows = self.connection.execute(
            "SELECT * FROM assets WHERE device_id = ? ORDER BY created_at, asset_id",
            (device_id,),
        ).fetchall()
        return tuple(self._asset(row) for row in rows)

    def prune_assets(self, device_id: str, retained_asset_ids: Iterable[str]) -> int:
        retained = sorted({asset_id for asset_id in retained_asset_ids if asset_id})
        with self.connection:
            self.connection.execute(
                "CREATE TEMP TABLE IF NOT EXISTS retained_assets (asset_id TEXT PRIMARY KEY) WITHOUT ROWID"
            )
            self.connection.execute("DELETE FROM retained_assets")
            self.connection.executemany(
                "INSERT INTO retained_assets (asset_id) VALUES (?)",
                ((asset_id,) for asset_id in retained),
            )
            for table in ("album_assets", "embeddings", "perceptual_hashes"):
                self.connection.execute(
                    f"""
                    DELETE FROM {table}
                    WHERE device_id = ?
                      AND asset_id NOT IN (SELECT asset_id FROM retained_assets)
                    """,
                    (device_id,),
                )
            result = self.connection.execute(
                """
                DELETE FROM assets
                WHERE device_id = ?
                  AND asset_id NOT IN (SELECT asset_id FROM retained_assets)
                """,
                (device_id,),
            )
            self.connection.execute("DELETE FROM retained_assets")
        return result.rowcount

    def replace_album_assets(
        self, device_id: str, album_id: str, asset_ids: Iterable[str]
    ) -> None:
        unique_ids = sorted({asset_id for asset_id in asset_ids if asset_id})
        with self.connection:
            self.connection.execute(
                "DELETE FROM album_assets WHERE device_id = ? AND album_id = ?",
                (device_id, album_id),
            )
            self.connection.executemany(
                "INSERT INTO album_assets (device_id, album_id, asset_id) VALUES (?, ?, ?)",
                ((device_id, album_id, asset_id) for asset_id in unique_ids),
            )

    def load_album_assets(self, device_id: str, album_id: str) -> tuple[str, ...]:
        rows = self.connection.execute(
            "SELECT asset_id FROM album_assets WHERE device_id = ? AND album_id = ? ORDER BY asset_id",
            (device_id, album_id),
        ).fetchall()
        return tuple(str(row["asset_id"]) for row in rows)

    def store_thumbnail(
        self, device_id: str, asset_id: str, content: bytes, media_type: str
    ) -> str:
        if not content:
            raise ValueError("thumbnail content cannot be empty")
        exists = self.connection.execute(
            "SELECT 1 FROM assets WHERE device_id = ? AND asset_id = ?",
            (device_id, asset_id),
        ).fetchone()
        if exists is None:
            raise KeyError(asset_id)
        digest = hashlib.sha256(content).hexdigest()
        path = self.object_path(digest)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(prefix="object-", dir=path.parent)
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(content)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        with self.connection:
            self.connection.execute(
                "INSERT OR IGNORE INTO objects (content_hash, media_type, byte_count) VALUES (?, ?, ?)",
                (digest, media_type, len(content)),
            )
            self.connection.execute(
                "UPDATE assets SET thumbnail_hash = ? WHERE device_id = ? AND asset_id = ?",
                (digest, device_id, asset_id),
            )
        return digest

    def thumbnail_path(self, device_id: str, asset_id: str) -> Path | None:
        row = self.connection.execute(
            "SELECT thumbnail_hash FROM assets WHERE device_id = ? AND asset_id = ?",
            (device_id, asset_id),
        ).fetchone()
        if row is None or row["thumbnail_hash"] is None:
            return None
        path = self.object_path(str(row["thumbnail_hash"]))
        return path if path.exists() else None

    def object_path(self, content_hash: str) -> Path:
        if len(content_hash) != 64 or any(
            character not in "0123456789abcdef" for character in content_hash
        ):
            raise ValueError("content_hash must be a lowercase SHA-256 digest")
        return self.object_directory / content_hash[:2] / content_hash[2:]

    def put_embedding(
        self, device_id: str, model_fingerprint: str, asset_id: str, vector: np.ndarray
    ) -> None:
        self.put_embeddings(device_id, model_fingerprint, [(asset_id, vector)])

    def put_embeddings(
        self,
        device_id: str,
        model_fingerprint: str,
        embeddings: Iterable[tuple[str, np.ndarray]],
    ) -> int:
        rows = []
        for asset_id, vector in embeddings:
            normalized = self._normalize_vector(vector)
            rows.append(
                (
                    device_id,
                    model_fingerprint,
                    asset_id,
                    normalized.size,
                    normalized.astype("<f2").tobytes(),
                )
            )
        if not rows:
            return 0
        with self.connection:
            self.connection.executemany(
                """
                INSERT INTO embeddings (device_id, model_fingerprint, asset_id, dimensions, vector)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(device_id, model_fingerprint, asset_id) DO UPDATE SET
                    dimensions = excluded.dimensions,
                    vector = excluded.vector
                """,
                rows,
            )
        return len(rows)

    def load_embeddings(
        self, device_id: str, model_fingerprint: str
    ) -> tuple[Embedding, ...]:
        rows = self.connection.execute(
            """
            SELECT asset_id, dimensions, vector FROM embeddings
            WHERE device_id = ? AND model_fingerprint = ? ORDER BY asset_id
            """,
            (device_id, model_fingerprint),
        ).fetchall()
        return tuple(
            Embedding(
                asset_id=str(row["asset_id"]),
                vector=np.frombuffer(
                    row["vector"], dtype="<f2", count=int(row["dimensions"])
                )
                .astype(np.float32)
                .copy(),
            )
            for row in rows
        )

    def put_hash(
        self, device_id: str, algorithm: str, asset_id: str, value: int, bits: int
    ) -> None:
        self.put_hashes(device_id, algorithm, [(asset_id, value)], bits)

    def put_hashes(
        self,
        device_id: str,
        algorithm: str,
        hashes: Iterable[tuple[str, int]],
        bits: int,
    ) -> int:
        if not algorithm or bits < 1:
            raise ValueError("invalid perceptual hash")
        width = (bits + 3) // 4
        rows = []
        for asset_id, value in hashes:
            if value < 0 or value.bit_length() > bits:
                raise ValueError("invalid perceptual hash")
            rows.append((device_id, algorithm, asset_id, bits, f"{value:0{width}x}"))
        if not rows:
            return 0
        with self.connection:
            self.connection.executemany(
                """
                INSERT INTO perceptual_hashes (device_id, algorithm, asset_id, bits, value)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(device_id, algorithm, asset_id) DO UPDATE SET
                    bits = excluded.bits,
                    value = excluded.value
                """,
                rows,
            )
        return len(rows)

    def load_hashes(self, device_id: str, algorithm: str) -> dict[str, int]:
        rows = self.connection.execute(
            """
            SELECT asset_id, value FROM perceptual_hashes
            WHERE device_id = ? AND algorithm = ? ORDER BY asset_id
            """,
            (device_id, algorithm),
        ).fetchall()
        return {str(row["asset_id"]): int(str(row["value"]), 16) for row in rows}

    def _migrate(self) -> None:
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS schema_info (
                version INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS assets (
                device_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                subtype TEXT,
                created_at TEXT,
                modified_at TEXT,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                duration REAL NOT NULL,
                is_favorite INTEGER NOT NULL,
                is_hidden INTEGER NOT NULL,
                has_location INTEGER NOT NULL,
                thumbnail_hash TEXT,
                PRIMARY KEY (device_id, asset_id)
            );
            CREATE TABLE IF NOT EXISTS album_assets (
                device_id TEXT NOT NULL,
                album_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                PRIMARY KEY (device_id, album_id, asset_id)
            );
            CREATE TABLE IF NOT EXISTS objects (
                content_hash TEXT PRIMARY KEY,
                media_type TEXT NOT NULL,
                byte_count INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS embeddings (
                device_id TEXT NOT NULL,
                model_fingerprint TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                dimensions INTEGER NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY (device_id, model_fingerprint, asset_id)
            );
            CREATE TABLE IF NOT EXISTS perceptual_hashes (
                device_id TEXT NOT NULL,
                algorithm TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                bits INTEGER NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (device_id, algorithm, asset_id)
            );
            """
        )
        row = self.connection.execute(
            "SELECT version FROM schema_info LIMIT 1"
        ).fetchone()
        if row is None:
            self.connection.execute(
                "INSERT INTO schema_info (version) VALUES (?)", (SCHEMA_VERSION,)
            )
            self.connection.commit()
        elif int(row["version"]) != SCHEMA_VERSION:
            raise RuntimeError(f"unsupported catalog schema version: {row['version']}")

    @staticmethod
    def _normalize_vector(vector: np.ndarray) -> np.ndarray:
        values = np.asarray(vector, dtype=np.float32)
        if values.ndim != 1 or values.size == 0 or not np.all(np.isfinite(values)):
            raise ValueError("embedding must be a finite one-dimensional vector")
        norm = float(np.linalg.norm(values))
        if norm == 0:
            raise ValueError("embedding cannot be zero")
        return values / norm

    @staticmethod
    def _date(value: object) -> str | None:
        return value.isoformat() if hasattr(value, "isoformat") else None

    @staticmethod
    def _asset(row: sqlite3.Row) -> Asset:
        from .models import parse_datetime

        return Asset(
            id=str(row["asset_id"]),
            kind=str(row["kind"]),
            subtype=str(row["subtype"]) if row["subtype"] is not None else None,
            created_at=parse_datetime(row["created_at"]),
            modified_at=parse_datetime(row["modified_at"]),
            pixel_width=int(row["pixel_width"]),
            pixel_height=int(row["pixel_height"]),
            duration=float(row["duration"]),
            is_favorite=bool(row["is_favorite"]),
            is_hidden=bool(row["is_hidden"]),
            has_location=bool(row["has_location"]),
        )
