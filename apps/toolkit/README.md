# 🧰 Photos Bridge Toolkit

照片桥的 Python 检索工具库，支持照片信息读取、本地缓存及向量相似度、感知哈希和拍摄时间邻近检索。

> [!NOTE]
>
> 工具库仅负责数据读取与检索，模型推理、筛选规则和相册整理由自定义工作流负责。

## 🚀 快速开始

在项目根目录安装，需要 Python 3.11+：

```bash
python -m pip install -e apps/toolkit
```

连接服务器，读取并保存照片信息：

```python
from photos_bridge_toolkit import BridgeClient, ToolkitStore

client = BridgeClient("http://127.0.0.1:8787", api_key="你的只读 API 密钥")

with ToolkitStore() as store:
    for page in client.iter_assets("你的设备 ID"):
        store.upsert_assets("你的设备 ID", page.items)
```

缩略图默认使用 `fit` 保留完整构图，方形裁剪可指定 `content_mode="fill"`。

## 📂 应用数据

默认保存到 `apps/toolkit/data`，可通过 `PHOTOS_BRIDGE_TOOLKIT_DATA_DIR` 修改。自定义工作流放在 `data/projects/`。
