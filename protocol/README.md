# Photos Bridge Protocol

Status: Draft (Protocol v1)  
Protocol version: 1

Photos Bridge Protocol is vendor-neutral. PhotoKit local identifiers are opaque
and device-scoped, and external callers never invoke arbitrary PhotoKit APIs.

## Envelope

Every device message uses the following envelope:

```json
{
  "protocol_version": 1,
  "message_id": "msg_01",
  "correlation_id": "request_01",
  "device_id": "device_01",
  "type": "assets.list.request",
  "sent_at": "2026-07-29T12:00:00Z",
  "payload": {}
}
```

Unknown versions and message types are rejected explicitly. Write messages
also bind a plan ID, canonical SHA-256 plan hash, operation ID, and idempotency
key. A timeout means the result is unknown, not that a write is safe to repeat.

## Capabilities

- `library.metadata.read`
- `library.albums.read`
- `assets.thumbnail.read`
- `albums.create`
- `albums.membership.write`

Original media, import, deletion, and precise location are out of scope for the
current profile.

Capabilities are selected during pairing. Album write capabilities default to
off, and enabling them never bypasses per-plan device approval. Both protocol
peers enforce the stored capability for every command; a declared but ungranted
capability produces `CAPABILITY_NOT_GRANTED`.

## Transport and recovery

The Apple client opens WSS only while iOS allows it to run. The Server stores
approval and undo commands in SQLite before delivery. A queued or sent command
is redelivered after device or Server restart until the device returns a
correlated receipt. Read requests are not queued: an offline device produces
`DEVICE_OFFLINE` rather than an empty library.

Device events receive an `event.ack` correlated to their message ID. The client
persists completion reports until that acknowledgement arrives. If it is
terminated after recording an operation as prepared but before recording the
PhotoKit result, it reports `operation.unknown` and never blindly repeats the
write.

## Protocol Messages

- `session.ready`
- `assets.list.request` / `assets.list.response`
- `assets.get.request` / `assets.get.response`
- `assets.thumbnail.request` / `assets.thumbnail.response`
- `albums.list.request` / `albums.list.response`
- `albums.assets.request` / `albums.assets.response`
- `plans.approval.request` / `plans.approval.response`
- `operation.executing`
- `operation.completed`
- `operation.unknown`
- `plan.rejected`
- `undo.approval.request` / `undo.approval.response`
- `undo.completed`
- `undo.rejected`
- `event.ack`

## Pagination

Asset cursors are opaque and bound to `snapshot_id`. The maximum page size is 500. A library change may invalidate a snapshot; the device then returns
`SNAPSHOT_INVALIDATED`, and the caller starts a new snapshot. Missing resources
under limited Photo access are not reported as deletions.

## Plan canonicalization

Plan and undo hashes are SHA-256 over canonical JSON with recursively sorted
object keys, compact separators, UTF-8 encoding, and stable array order. Asset
IDs are deduplicated and sorted before hashing. The device reconstructs and
verifies the same canonical content before presenting approval.
