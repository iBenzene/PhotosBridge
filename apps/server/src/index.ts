/**
 * @file index.ts
 * @description Server entry point handling startup initialization and CLI server runner.
 * @author iBenzene
 */
import http from "node:http";
import QRCode from "qrcode";
import { createApp } from "./app.js";
import { prepareEnvironment } from "./auto-config.js";
import { loadConfig } from "./config.js";
import { PhotosBridgeDatabase } from "./database.js";
import { DeviceHub } from "./device-hub.js";

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
