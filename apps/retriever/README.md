# Photos Bridge Retriever

`apps/retriever` is a deliberately small, read-only retrieval foundation for
private workflows. It does not contain task-specific recognition, clustering,
ranking, model training, review UI, or album-write orchestration.

## Responsibilities

- Read library metadata, album membership, and thumbnails through the public
  Photos Bridge Server API.
- Persist a local asset catalog and content-addressed thumbnail objects.
- Persist model-identified embeddings and perceptual hashes without loading or
  training any model.
- Provide exact cosine, perceptual-hash, and temporal-neighbor search primitives.

Everything that decides what to retrieve belongs to a private workflow under
`data/projects/` or another ignored location.

## Data directory

The default data directory is `apps/retriever/data`. Override it with
`PHOTOS_BRIDGE_RETRIEVER_DATA_DIR` when needed. Runtime data is ignored by Git.

## Example workflow

```python
from photos_bridge_retriever import BridgeClient, RetrieverStore, cosine_search

client = BridgeClient("http://127.0.0.1:8787", api_key="library-read-key")
store = RetrieverStore()

page = client.list_assets("device_01", limit=500)
store.upsert_assets("device_01", page.items)
thumbnail, media_type = client.get_thumbnail("device_01", page.items[0].id)

queries = workflow_encoder(reference_images)
candidates = store.load_embeddings("device_01", "model-fingerprint")
matches = cosine_search(queries, candidates, top_k=100)
```

`BridgeClient.get_thumbnail()` defaults to `content_mode="fit"` so retrieval
indexes receive the complete thumbnail composition. Pass `content_mode="fill"`
only for UI-style square crops. The client rejects other values before making an
HTTP request.

The encoder, reference selection, thresholds, evidence fusion, and review flow
in this example are intentionally owned by the workflow.

## Tests

```powershell
python -m pytest --rootdir apps/retriever apps/retriever/tests
```
