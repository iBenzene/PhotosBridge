# 📸 Photos Bridge

> 🌉 An open protocol and gateway bridging Apple Photos (iOS/iPadOS) with self-hosted servers.

**Photos Bridge** enables your iPhone or iPad to seamlessly and securely exchange approved metadata, album-management plans, and thumbnails with your private server.

## ✨ Features & Highlights

- 🛡️ **Zero-Trust Security Boundary**: Original media export, deletion, and background location tracking are strictly disabled by default.
- 📱 **Native Apple Client**: Built with SwiftUI & PhotoKit for ultra-fast, smooth performance on iOS & iPadOS.
- ⚡ **Developer-Friendly Server**: Powered by Node.js, Express, WebSocket, and SQLite with auto-configuration and terminal QR code generation.
- 🔑 **Instant Zero-Config Pairing**: Automatically detects local IP addresses, generates pairing tokens, and renders a terminal QR code for one-scan setup.
- 📦 **Monorepo Architecture**: Clean separation between Apple Client (`apps/apple`), Reference Server (`apps/server`), and Protocol Spec (`protocol`).

## 🛠️ Requirements

- 🍎 **iOS / iPadOS**: `17.0` or newer
- 🛠️ **Xcode**: `16.0` or newer (for iOS simulator runtime & physical device deployment)
- 🟢 **Node.js**: `24.0` or newer
- 🐳 **Docker**: Docker Desktop (optional, for containerized deployment)

## 🚀 Quick Start

### 1. 🟢 Server Setup (`apps/server`)

Install dependencies and launch the server:

```sh
npm install
npm run dev:server
```

💡 **What happens on startup?**

1. 🔍 **Auto IP Detection**: Interactively prompts you to select your local IP.
2. 🔑 **Auto Admin Key**: Generates a random `PHOTOS_BRIDGE_ADMIN_KEY` if unset.
3. 🎟️ **Instant QR Code**: Renders a QR code directly in your terminal for 1-tap app pairing!

### 2. 📱 Apple Client (`apps/apple`)

1. Open `apps/apple/PhotosBridge.xcodeproj` in Xcode.
2. Select the `PhotosBridge` scheme and run it on an iPhone/iPad (or Simulator).
3. Tap **"Scan QR Code"** in the app and scan the terminal QR code to pair instantly! 🎉

> 💡 **Command-line build:**
>
> ```sh
> xcodebuild -project apps/apple/PhotosBridge.xcodeproj \
>   -scheme PhotosBridge \
>   -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
> ```

### 3. 🐳 Docker Deployment

Run with Docker Compose in production:

```sh
docker build -f apps/server/Dockerfile -t photos-bridge-server:latest .
PUBLIC_BASE_URL='https://bridge.example.com' \
PHOTOS_BRIDGE_ADMIN_KEY='your-high-entropy-key' \
docker compose up -d
```

> 💾 All SQLite data and pairing states are persisted in `/data` volume.

## 🧪 Testing & Quality

Run the server build and test suite:

```sh
npm run build:server
npm run test:server
```

Run code formatting and linting:

```sh
npm run lint
npm run format
```

## 📄 Protocol & Specifications

- 📜 Communication protocol & message schemas: [`protocol/README.md`](protocol/README.md)
- 🌐 OpenAPI Specification: [`protocol/openapi.yaml`](protocol/openapi.yaml)

## ⚖️ License & Disclaimer

This project is licensed under the [MIT License](LICENSE).

Photos Bridge is an independent open-source project and is not affiliated with or endorsed by Apple Inc.
