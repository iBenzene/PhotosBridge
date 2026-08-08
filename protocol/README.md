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

Unknown versions and message types are rejected explicitly. Plan delivery binds
the immutable plan ID, target device, and canonical SHA-256 content hash. The
device receipt only confirms durable local storage.

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
peers enforce the stored capability for every applicable request; a declared but ungranted
capability produces `CAPABILITY_NOT_GRANTED`.

## Transport and recovery

The Apple client opens WSS only while iOS allows it to run. The Server stores
plan deliveries in SQLite and redelivers them after device or Server
restart until the device returns a correlated receipt confirming that the plan
was validated and durably stored. That receipt ends the Server's responsibility
for the plan. Approval, rejection, execution, undo, restore, and their history
remain entirely on the device and are never reported back to the Server. Read
requests are not queued: an offline device produces `DEVICE_OFFLINE` rather
than an empty library.

## Protocol Messages

- `session.ready`
- `assets.list.request` / `assets.list.response`
- `assets.get.request` / `assets.get.response`
- `assets.thumbnail.request` / `assets.thumbnail.response`
- `albums.list.request` / `albums.list.response`
- `albums.assets.request` / `albums.assets.response`
- `plans.delivery.request` / `plans.delivery.response`

## Pagination

Asset cursors are opaque and bound to `snapshot_id`. The maximum page size is 500. A library change may invalidate a snapshot; the device then returns
`SNAPSHOT_INVALIDATED`, and the caller starts a new snapshot. Missing resources
under limited Photo access are not reported as deletions.

## Plan canonicalization

Plan hashes are SHA-256 over canonical JSON with recursively sorted
object keys, compact separators, UTF-8 encoding, and stable array order. Asset
IDs are deduplicated and sorted before hashing. The device reconstructs and
verifies the same canonical content before presenting approval.
