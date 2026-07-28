/**
 * @file config.ts
 * @description Server configuration parser and environment settings loader.
 * @author iBenzene
 */
import path from "node:path";

export type ServerConfig = {
    port: number;
    databasePath: string;
    publicBaseURL: string;
    adminKey?: string;
    rateLimitPerMinute?: number;
};

export const loadConfig = (environment: NodeJS.ProcessEnv = process.env): ServerConfig => ({
    adminKey: environment.PHOTOS_BRIDGE_ADMIN_KEY,
    databasePath: path.resolve(environment.DATABASE_PATH ?? "data/photos-bridge.sqlite"),
    port: Number(environment.PORT ?? 8787),
    publicBaseURL: environment.PUBLIC_BASE_URL ?? "http://127.0.0.1:8787",
    rateLimitPerMinute: Number(environment.PHOTOS_BRIDGE_RATE_LIMIT_PER_MINUTE ?? 300),
});
