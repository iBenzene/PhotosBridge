PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  app_version TEXT NOT NULL,
  protocol_version INTEGER NOT NULL,
  capabilities_json TEXT NOT NULL,
  paired_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS device_credentials (
  device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  secret_hash TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS api_keys (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  key_hash TEXT NOT NULL UNIQUE,
  scopes_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS pairing_sessions (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  server_url TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS commands (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL,
  correlation_id TEXT,
  result_json TEXT,
  error_code TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS plans (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  idempotency_key TEXT NOT NULL,
  requester_key_id TEXT NOT NULL REFERENCES api_keys(id),
  summary TEXT NOT NULL,
  target_album_json TEXT NOT NULL,
  asset_ids_json TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(device_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS operations (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id),
  batch_id TEXT UNIQUE,
  status TEXT NOT NULL,
  counts_json TEXT,
  failures_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS batch_items (
  batch_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  target_album_id TEXT NOT NULL,
  undone_at TEXT,
  PRIMARY KEY(batch_id, asset_id)
);

CREATE TABLE IF NOT EXISTS undo_plans (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(id),
  target_album_id TEXT NOT NULL,
  asset_ids_json TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_events (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  actor_type TEXT NOT NULL,
  actor_id TEXT,
  device_id TEXT,
  plan_id TEXT,
  operation_id TEXT,
  details_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS commands_device_status_idx ON commands(device_id, status);
CREATE INDEX IF NOT EXISTS plans_device_status_idx ON plans(device_id, status);
CREATE INDEX IF NOT EXISTS audit_created_idx ON audit_events(created_at);
