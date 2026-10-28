# 🧰 Photos Bridge Toolkit

照片桥的 Python 软件开发工具包（SDK），供自定义工作流、Python 脚本或 AI 智能体调用。封装了服务端交互、照片数据缓存与多维度相似检索等功能。

## 🚀 快速开始

在项目根目录安装，需要 Python 3.11+：

```bash
python -m pip install -e apps/toolkit
```

在工作流中连接服务器，并将照片元数据同步到指定目录：

```python
from pathlib import Path
from photos_bridge_toolkit import BridgeClient, ToolkitStore, sync_assets

client = BridgeClient("http://127.0.0.1:8787", api_key="你的只读 API 密钥")
device_id = "你的设备 ID"
cache_directory = Path(__file__).resolve().parent / "data" / "photos-cache"

with ToolkitStore(root=cache_directory) as store:
    sync_assets(client, store, device_id)

    # 下载缩略图
    from photos_bridge_toolkit import cache_thumbnails

    cache_thumbnails(
        client,
        store,
        device_id,
        (asset.id for asset in store.load_assets(device_id))
    )
```

缩略图默认使用 `fit` 保留完整构图，方形裁剪可指定 `content_mode="fill"`。
