/**
 * @file index.ts
 * @description Server entry point handling startup initialization and CLI server runner.
 * @author iBenzene
 */
import http from "node:http";
import os from "node:os";
import crypto from "node:crypto";
import readline from "node:readline/promises";
import QRCode from "qrcode";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { PhotosBridgeDatabase } from "./database.js";
import { DeviceHub } from "./device-hub.js";

const getLocalIPv4Addresses = (): string[] => {
    const interfaces = os.networkInterfaces();
    const ips: string[] = [];
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name] ?? []) {
            if (iface.family === "IPv4" && !iface.internal) {
                ips.push(iface.address);
            }
        }
    }
    return ips;
};

const prepareEnvironment = async (): Promise<void> => {
    const isProduction = process.env.NODE_ENV === "production";

    // 1. Auto-generate admin key if not set
    if (!process.env.PHOTOS_BRIDGE_ADMIN_KEY) {
        const autoKey = crypto.randomBytes(16).toString("hex");
        process.env.PHOTOS_BRIDGE_ADMIN_KEY = autoKey;
        console.log(`💡 [Auto-Config] Generated random PHOTOS_BRIDGE_ADMIN_KEY: ${autoKey}`);
    }

    // 2. PUBLIC_BASE_URL check: Mandatory in production mode, auto-detected in development
    if (!process.env.PUBLIC_BASE_URL) {
        if (isProduction) {
            throw new Error("Fatal Error: PUBLIC_BASE_URL environment variable is mandatory in production mode.");
        }

        const port = Number(process.env.PORT ?? 8787);
        const localIPs = getLocalIPv4Addresses();
        const availableIPs = [...localIPs, "127.0.0.1"];

        let selectedIP = availableIPs[0];

        if (process.stdin.isTTY && availableIPs.length > 1) {
            console.log("\n🔍 PUBLIC_BASE_URL is unset. Available local IP addresses:");
            availableIPs.forEach((ip, index) => {
                const hint =
                    index === 0
                        ? " (Recommended for physical devices)"
                        : ip === "127.0.0.1"
                          ? " (Localhost/Simulator only)"
                          : "";
                console.log(`  [${index + 1}] http://${ip}:${port}${hint}`);
            });

            const rl = readline.createInterface({
                input: process.stdin,
                output: process.stdout,
            });

            try {
                const answer = await rl.question(`\nSelect IP number for pairing [default 1: ${selectedIP}]: `);
                const choice = parseInt(answer.trim(), 10);
                if (!isNaN(choice) && choice >= 1 && choice <= availableIPs.length) {
                    selectedIP = availableIPs[choice - 1];
                }
            } catch {
                // Fallback to default
            } finally {
                rl.close();
            }
        }

        process.env.PUBLIC_BASE_URL = `http://${selectedIP}:${port}`;
        console.log(`💡 [Auto-Config] Set PUBLIC_BASE_URL to: ${process.env.PUBLIC_BASE_URL}`);
    }
};

const startServer = async (): Promise<void> => {
    await prepareEnvironment();

    const config = loadConfig();
    const database = new PhotosBridgeDatabase(config.databasePath);
    if (config.adminKey) database.seedAdminKey(config.adminKey);

    const hub = new DeviceHub(database);
    const app = createApp({ config, database, hub });
    const server = http.createServer(app);
    hub.attach(server);

    server.listen(config.port, "0.0.0.0", async () => {
        console.log(`\n====================================================================`);
        console.log(`🚀 Photos Bridge Server 0.1.0 listening on port ${config.port}`);
        console.log(`====================================================================`);
        console.log(`📍 Base URL:   ${config.publicBaseURL}`);
        console.log(`🔑 Admin Key:  ${config.adminKey}`);
        console.log(`--------------------------------------------------------------------`);

        // Automatically create a pairing session (valid for 24 hours)
        const session = database.createPairingSession(86400);

        const qrPayload = {
            expires_at: session.expiresAt,
            pairing_token: session.token,
            server_url: config.publicBaseURL,
        };

        console.log(`🎟️  Pairing Token: ${session.token}`);
        console.log(`⏳ Expires At:     24 hours (${session.expiresAt})`);
        console.log(`\n📱 Scan QR Code in iOS Photos Bridge App ("Scan QR Code"): \n`);

        try {
            const qrTerminal = await QRCode.toString(JSON.stringify(qrPayload), {
                small: true,
                type: "terminal",
            });
            console.log(qrTerminal);
        } catch (err) {
            console.error("Failed to generate QR code:", err);
        }

        console.log(`====================================================================\n`);
    });

    const shutdown = (): void => {
        server.close(() => {
            database.close();
            process.exit(0);
        });
    };
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
};

startServer().catch(err => {
    console.error("Failed to start server:", err);
    process.exit(1);
});
