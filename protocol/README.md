# Photos Bridge Protocol

Status: Draft (Protocol v1.1 profile)
Transport protocol version: 1

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

`assets.thumbnail.request` accepts `asset_id`, optional `max_dimension`, and
optional `content_mode`. Missing `content_mode` means `fill` for backward
compatibility. `content_mode=fill` requests a UI-style aspect-fill thumbnail;
`content_mode=fit` requests an aspect-fit thumbnail that preserves the full
composition. Other values are rejected explicitly and never mapped to PhotoKit.

## Pagination

Asset cursors are opaque and bound to `snapshot_id`. The maximum page size is 500. A library change may invalidate a snapshot; the device then returns
`SNAPSHOT_INVALIDATED`, and the caller starts a new snapshot. Missing resources
under limited Photo access are not reported as deletions.

## Plan canonicalization

Plan hashes are SHA-256 over canonical JSON with recursively sorted
object keys, compact separators, UTF-8 encoding, and stable array order. Asset
IDs are deduplicated and sorted before hashing. The device reconstructs and
verifies the same canonical content before presenting approval.

Write plans created by the v1.1 profile include an explicit `operation` field:

- `album_members.add` requires `target_album` and may create it.
- `album_members.remove` requires an existing `source_album` identified by its
  device-scoped album ID.
- `album_members.move` requires existing source and target album IDs. The
  device adds members to the target and removes them from the source in one
  PhotoKit change transaction. It rejects target creation and identical source
  and target IDs.

The operation and all operation-specific album references are part of the
canonical hashed content, so changing any of them invalidates the plan.

For rolling upgrades, peers accept legacy plans without `operation` and treat
them as `album_members.add`; legacy hashes are verified without injecting the
missing field. New plans always include `operation`. Unknown operation values
or invalid field combinations are rejected explicitly and are never mapped to
a PhotoKit action.
