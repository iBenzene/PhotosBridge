PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  app_version TEXT NOT NULL,
  capabilities_json TEXT NOT NULL,
  paired_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS device_credentials (
  device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  secret_hash TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS api_keys (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  key_hash TEXT NOT NULL UNIQUE,
  scopes_json TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS pairing_sessions (
  token_hash TEXT PRIMARY KEY,
  expires_at TEXT NOT NULL,
  consumed INTEGER NOT NULL DEFAULT 0 CHECK (consumed IN (0, 1))
);

CREATE TABLE IF NOT EXISTS plans (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  idempotency_key TEXT NOT NULL,
  summary TEXT NOT NULL,
  target_album_json TEXT NOT NULL,
  asset_ids_json TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(device_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS plan_deliveries (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id),
  status TEXT NOT NULL CHECK (status IN ('queued', 'sent', 'stored', 'failed', 'expired')),
  created_at TEXT NOT NULL,
  delivery_expires_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS plan_deliveries_status_idx ON plan_deliveries(status);
CREATE INDEX IF NOT EXISTS plan_deliveries_plan_idx ON plan_deliveries(plan_id, created_at);
