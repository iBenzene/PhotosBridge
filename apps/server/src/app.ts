/**
 * @file app.ts
 * @description Express application setup, middleware configuration, and core API routing.
 * @author iBenzene
 */
import express, { type NextFunction, type Request, type Response } from "express";
import type { ServerConfig } from "./config.js";
import { PairingError, PhotosBridgeDatabase } from "./database.js";
import { DeviceOfflineError, DeviceResponseError, DeviceTimeoutError, type DeviceHub } from "./device-hub.js";
import { PlanError, PlanService, type PlanInput } from "./plans.js";

const DEFAULT_DELIVERY_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export type AppDependencies = {
    config: ServerConfig;
    database: PhotosBridgeDatabase;
    hub: DeviceHub;
};

export const createApp = ({ config, database, hub }: AppDependencies): express.Express => {
    const app = express();
    const plans = new PlanService(database);
    app.disable("x-powered-by");
    app.use(express.json({ limit: "1mb" }));
    app.use(rateLimit(config.rateLimitPerMinute ?? 300, 60_000));
    app.use((request, response, next) => {
        response.setHeader("X-Request-ID", request.header("X-Request-ID") ?? crypto.randomUUID());
        next();
    });

    app.get("/health", (_request, response) => {
        response.json({ protocol_version: 1, status: "ok", version: "0.1.0" });
    });

    app.post(
        "/api/v1/pairing-sessions",
        rateLimit(10, 60_000),
        requireScope(database, "admin"),
        (_request, response) => {
            const session = database.createPairingSession();
            response.status(201).json({
                expires_at: session.expiresAt,
                pairing_token: session.token,
                server_url: config.publicBaseURL,
            });
        }
    );

    app.post("/api/v1/api-keys", requireScope(database, "admin"), (request, response) => {
        const body = request.body as Record<string, unknown>;
        try {
            const created = database.createAPIKey(
                String(body.name ?? ""),
                Array.isArray(body.scopes) ? body.scopes.map(String) : []
            );
            response.status(201).json({ api_key: created.key, api_key_id: created.id, scopes: created.scopes });
        } catch {
            response.status(400).json({ error: { code: "INVALID_API_KEY" } });
        }
    });

    app.delete("/api/v1/api-keys/:keyID", requireScope(database, "admin"), (request, response) => {
        if (!database.revokeAPIKey(String(request.params.keyID))) {
            return response.status(404).json({ error: { code: "API_KEY_NOT_FOUND" } });
        }
        return response.status(204).send();
    });

    app.post("/device/v1/pair", (request, response, next) => {
        try {
            const body = request.body as Record<string, unknown>;
            if (!body.pairing_token || !body.display_name || !body.app_version || !body.protocol_version) {
                return response.status(400).json({ error: { code: "INVALID_REQUEST" } });
            }
            const credentials = database.pairDevice({
                appVersion: String(body.app_version),
                capabilities: Array.isArray(body.capabilities) ? body.capabilities.map(String) : [],
                displayName: String(body.display_name),
                protocolVersion: Number(body.protocol_version),
                token: String(body.pairing_token),
            });
            return response.status(201).json({
                device_id: credentials.deviceID,
                device_secret: credentials.deviceSecret,
            });
        } catch (error) {
            return next(error);
        }
    });
    app.post("/device/v1/unpair", (request, response) => {
        const body = request.body as Record<string, unknown>;
        const deviceID = String(body.device_id ?? "");
        const authorization = request.header("Authorization") ?? "";
        const secret = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
        if (!deviceID || !secret || !database.authenticateDevice(deviceID, secret)) {
            return response.status(401).json({ error: { code: "AUTHENTICATION_FAILED" } });
        }
        database.revokeDevice(deviceID);
        hub.disconnect(deviceID);
        return response.status(204).send();
    });

    app.get("/api/v1/devices", requireScope(database, "library.read"), (_request, response) => {
        response.json({
            devices: database.listDevices().map(device => presentDevice(device, hub.isOnline(device.id))),
        });
    });

    app.get("/api/v1/devices/:deviceID", requireScope(database, "library.read"), (request, response) => {
        const deviceID = String(request.params.deviceID);
        const device = database.getDevice(deviceID);
        if (!device) return response.status(404).json({ error: { code: "DEVICE_NOT_FOUND" } });
        return response.json(presentDevice(device, hub.isOnline(device.id)));
    });

    app.delete("/api/v1/devices/:deviceID", requireScope(database, "admin"), (request, response) => {
        const deviceID = String(request.params.deviceID);
        if (!database.revokeDevice(deviceID)) return response.status(404).json({ error: { code: "DEVICE_NOT_FOUND" } });
        hub.disconnect(deviceID);
        return response.status(204).send();
    });

    app.get(
        "/api/v1/devices/:deviceID/albums",
        requireScope(database, "library.read"),
        requireDeviceCapability(database, "library.albums.read"),
        bridge(hub, "albums.list.request")
    );
    app.get(
        "/api/v1/devices/:deviceID/albums/:albumID/assets",
        requireScope(database, "library.read"),
        requireDeviceCapability(database, "library.albums.read"),
        bridge(hub, "albums.assets.request")
    );
    app.get(
        "/api/v1/devices/:deviceID/assets",
        requireScope(database, "library.read"),
        requireDeviceCapability(database, "library.metadata.read"),
        bridge(hub, "assets.list.request")
    );
    app.get(
        "/api/v1/devices/:deviceID/assets/:assetID",
        requireScope(database, "library.read"),
        requireDeviceCapability(database, "library.metadata.read"),
        bridge(hub, "assets.get.request")
    );
    app.get(
        "/api/v1/devices/:deviceID/assets/:assetID/thumbnail",
        requireScope(database, "library.read"),
        requireDeviceCapability(database, "assets.thumbnail.read"),
        async (request, response, next) => {
            try {
                const contentMode = parseThumbnailContentMode(request.query.content_mode);
                if (!contentMode) {
                    return void response.status(400).json({ error: { code: "INVALID_THUMBNAIL_CONTENT_MODE" } });
                }
                const payload = (await hub.request(String(request.params.deviceID), "assets.thumbnail.request", {
                    asset_id: String(request.params.assetID),
                    content_mode: contentMode,
                    max_dimension: Math.min(Number(request.query.max_dimension ?? 768), 1024),
                })) as { data_base64?: string; mime_type?: string };
                if (!payload.data_base64)
                    return void response.status(502).json({ error: { code: "THUMBNAIL_GENERATION_FAILED" } });
                response.type(payload.mime_type ?? "image/jpeg").send(Buffer.from(payload.data_base64, "base64"));
            } catch (error) {
                next(error);
            }
        }
    );

    app.post("/api/v1/plans", requireScope(database, "plans.write"), (request, response, next) => {
        try {
            response.status(201).json(plans.create(request.body as PlanInput));
        } catch (error) {
            next(error);
        }
    });
    app.get("/api/v1/plans/:planID", requireScope(database, "plans.write"), (request, response) => {
        const plan = plans.get(String(request.params.planID));
        if (!plan) return response.status(404).json({ error: { code: "PLAN_NOT_FOUND" } });
        return response.json(plan);
    });
    app.post("/api/v1/plans/:planID/deliver", requireScope(database, "plans.write"), (request, response, next) => {
        try {
            const planID = String(request.params.planID);
            const plan = plans.get(planID);
            if (!plan) throw new PlanError("PLAN_NOT_FOUND", 404);
            const deliveryExpiresAt = new Date(Date.now() + DEFAULT_DELIVERY_TTL_MS).toISOString();
            response.status(202).json(hub.enqueuePlanDelivery(planID, deliveryExpiresAt));
        } catch (error) {
            next(error);
        }
    });
    app.get("/api/v1/plans/:planID/delivery", requireScope(database, "plans.write"), (request, response) => {
        const delivery = hub.getLatestPlanDelivery(String(request.params.planID));
        if (!delivery) return response.status(404).json({ error: { code: "DELIVERY_NOT_FOUND" } });
        return response.json(delivery);
    });
    app.use((_request, response) => response.status(404).json({ error: { code: "NOT_FOUND" } }));
    app.use((error: unknown, _request: Request, response: Response, _next: NextFunction) => {
        if (error instanceof PairingError) return response.status(error.status).json({ error: { code: error.code } });
        if (error instanceof PlanError) return response.status(error.status).json({ error: { code: error.code } });
        if (error instanceof DeviceOfflineError) return response.status(503).json({ error: { code: error.code } });
        if (error instanceof DeviceTimeoutError) return response.status(504).json({ error: { code: error.code } });
        if (error instanceof DeviceResponseError)
            return response.status(502).json({ error: { code: error.code, details: error.payload } });
        console.error("Unhandled request error", error);
        return response.status(500).json({ error: { code: "INTERNAL_ERROR" } });
    });
    return app;
};

const parseThumbnailContentMode = (value: unknown): "fit" | "fill" | undefined => {
    if (value === undefined) return "fill";
    return value === "fit" || value === "fill" ? value : undefined;
};

const requireScope =
    (database: PhotosBridgeDatabase, scope: string) =>
    (request: Request, response: Response, next: NextFunction): void => {
        const authorization = request.header("Authorization");
        const key = authorization?.startsWith("Bearer ") ? authorization.slice(7) : "";
        const principal = key ? database.authenticateAPIKey(key) : null;
        if (!principal) return void response.status(401).json({ error: { code: "AUTHENTICATION_FAILED" } });
        if (!principal.scopes.includes("admin") && !principal.scopes.includes(scope)) {
            return void response.status(403).json({ error: { code: "CAPABILITY_NOT_GRANTED" } });
        }
        next();
    };

const bridge =
    (hub: DeviceHub, type: string) =>
    async (request: Request, response: Response, next: NextFunction): Promise<void> => {
        try {
            const payload = {
                ...request.query,
                ...(request.params.assetID ? { asset_id: request.params.assetID } : {}),
                ...(request.params.albumID ? { album_id: request.params.albumID } : {}),
            };
            response.json(await hub.request(String(request.params.deviceID), type, payload));
        } catch (error) {
            next(error);
        }
    };

const requireDeviceCapability =
    (database: PhotosBridgeDatabase, capability: string) =>
    (request: Request, response: Response, next: NextFunction): void => {
        const device = database.getDevice(String(request.params.deviceID));
        if (!device) return void response.status(404).json({ error: { code: "DEVICE_NOT_FOUND" } });
        const capabilities = JSON.parse(device.capabilities_json) as string[];
        if (!capabilities.includes(capability)) {
            return void response.status(403).json({ error: { capability, code: "CAPABILITY_NOT_GRANTED" } });
        }
        next();
    };

const presentDevice = (
    device: ReturnType<PhotosBridgeDatabase["getDevice"]> & NonNullable<unknown>,
    online: boolean
) => {
    if (!device) return device;
    return {
        app_version: device.app_version,
        capabilities: JSON.parse(device.capabilities_json) as string[],
        device_id: device.id,
        display_name: device.display_name,
        last_seen_at: device.last_seen_at,
        online,
        paired_at: device.paired_at,
    };
};

const rateLimit = (maximum: number, windowMilliseconds: number) => {
    const buckets = new Map<string, { count: number; resetsAt: number }>();
    return (request: Request, response: Response, next: NextFunction): void => {
        const key = request.ip ?? request.socket.remoteAddress ?? "unknown";
        const timestamp = Date.now();
        const current = buckets.get(key);
        const bucket =
            !current || current.resetsAt <= timestamp
                ? { count: 0, resetsAt: timestamp + windowMilliseconds }
                : current;
        bucket.count += 1;
        buckets.set(key, bucket);
        response.setHeader("RateLimit-Limit", String(maximum));
        response.setHeader("RateLimit-Remaining", String(Math.max(0, maximum - bucket.count)));
        if (bucket.count > maximum) {
            response.setHeader("Retry-After", String(Math.ceil((bucket.resetsAt - timestamp) / 1000)));
            response.status(429).json({ error: { code: "RATE_LIMITED" } });
            return;
        }
        next();
    };
};
