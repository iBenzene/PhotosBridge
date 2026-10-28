# src/photos_bridge_toolkit/sync.py

from collections.abc import Iterable

from .bridge import BridgeClient, ThumbnailContentMode
from .store import ToolkitStore


def sync_assets(
    client: BridgeClient, store: ToolkitStore, device_id: str, *, limit: int = 500
) -> int:
    """分页同步指定远端设备上的全部照片元数据, 返回写入的记录总数。

    采用增量合并写入模式, 本地已有记录不会被删除。执行过程中若发生中断,
    已拉取成功的分页依然保留在本地数据库中, 由调用方控制重试逻辑。
    """
    count = 0
    for page in client.iter_assets(device_id, limit=limit):
        count += store.upsert_assets(device_id, page.items)
    return count


def cache_thumbnails(
    client: BridgeClient,
    store: ToolkitStore,
    device_id: str,
    asset_ids: Iterable[str],
    *,
    max_dimension: int = 518,
    content_mode: ThumbnailContentMode = "fit",
    refresh: bool = False,
) -> int:
    """为已编目的照片批量拉取并本地缓存缩略图, 返回本次实际下载的照片数量。

    若本地已存在缓存文件则直接复用, 传入 refresh=True 时强制重新拉取覆盖。
    发生网络或服务端异常时直接向外抛出, 已成功写入磁盘的文件依然保留供后续复用。
    """
    if not 1 <= max_dimension <= 1024:
        raise ValueError("max_dimension must be between 1 and 1024")
    if content_mode not in ("fit", "fill"):
        raise ValueError("content_mode must be 'fit' or 'fill'")
    count = 0
    for asset_id in asset_ids:
        if not refresh and store.thumbnail_path(device_id, asset_id) is not None:
            continue
        content, media_type = client.get_thumbnail(
            device_id,
            asset_id,
            max_dimension=max_dimension,
            content_mode=content_mode,
        )
        store.store_thumbnail(device_id, asset_id, content, media_type)
        count += 1
    return count
