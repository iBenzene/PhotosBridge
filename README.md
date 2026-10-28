# 照片桥

🌉 给 Apple 相册打造的开放桥梁，让你的自定义工作流与 AI Agent 可以接管并智能整理你的相册。

## 🚀 快速开始

### 🟢 本地启动服务端

```bash
npm install
npm run dev:server
```

（可选）🐳 Docker 部署

```bash
sudo docker pull ghcr.io/ibenzene/photos-bridge_server:latest
PUBLIC_BASE_URL='https://bridge.example.com' \
ADMIN_KEY='your-high-entropy-key' \
sudo docker compose up -d
```

### 📱 连接 iOS 客户端

打开 App 点击「配对服务器」，扫描二维码即可配对 🎉。
