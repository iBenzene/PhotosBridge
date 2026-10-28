// src/index.ts

import http from 'node:http';
import { createApp } from './app.js';
import { prepareEnvironment } from './auto-config.js';
import { loadConfig } from './config.js';
import { PhotosBridgeDatabase } from './database.js';
import { DeviceHub } from './device-hub.js';

const startServer = async (): Promise<void> => {
    await prepareEnvironment();

    const config = loadConfig();
    const database = new PhotosBridgeDatabase(config.databasePath);
    if (config.adminKey) {
        database.seedAdminKey(config.adminKey);
    }

    const hub = new DeviceHub(database);
    const app = createApp({ config, database, hub });
    const server = http.createServer(app);
    hub.attach(server);

    server.listen(config.port, '0.0.0.0', () => {
        console.log(`Photos Bridge listening on port ${config.port}`);
        console.log(
            `Admin panel: ${config.publicBaseURL.replace(/\/$/, '')}/ui/`
        );
    });
    const shutdown = (): void => {
        server.close(() => {
            database.close();
            process.exit(0);
        });
    };
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
};

startServer().catch(err => {
    console.error('Failed to start server:', err);
    process.exit(1);
});
