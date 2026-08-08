/**
 * @file database.ts
 * @description SQLite database management, schema migrations, and persistence layer.
 * @author iBenzene
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import Database from "better-sqlite3";

export type DeviceRecord = {
    id: string;
    display_name: string;
    app_version: string;
    capabilities_json: string;
    paired_at: string;
    last_seen_at: string | null;
    revoked_at: string | null;
};

export class PhotosBridgeDatabase {
    readonly connection: Database.Database;

    constructor(databasePath: string, migrationPath = path.resolve("migrations/001_initial.sql")) {
        if (databasePath !== ":memory:") fs.mkdirSync(path.dirname(databasePath), { recursive: true });
        this.connection = new Database(databasePath);
        this.connection.pragma("journal_mode = WAL");
        this.connection.pragma("foreign_keys = ON");
        this.connection.pragma("busy_timeout = 5000");
        this.connection.exec(fs.readFileSync(migrationPath, "utf8"));
    }

    close(): void {
        this.connection.close();
    }

    seedAdminKey(key: string): void {
        const existing = this.connection
            .prepare("SELECT id FROM api_keys WHERE name = ? AND revoked_at IS NULL")
            .get("bootstrap-admin");
        if (existing) return;
        this.connection
            .prepare(
                `
      INSERT INTO api_keys (id, name, key_hash, scopes_json)
      VALUES (?, ?, ?, ?)
    `
            )
            .run(
                id("key"),
                "bootstrap-admin",
                hashSecret(key),
                JSON.stringify(["admin", "library.read", "plans.write"])
            );
    }

    createAPIKey(name: string, scopes: string[]): { id: string; key: string; scopes: string[] } {
        const allowed = new Set(["admin", "library.read", "plans.write"]);
        const normalizedScopes = [...new Set(scopes)].filter(scope => allowed.has(scope)).sort();
        if (!name.trim() || normalizedScopes.length === 0) throw new Error("INVALID_API_KEY");
        const keyID = id("key");
        const key = `pbk_${crypto.randomBytes(32).toString("base64url")}`;
        this.connection
            .prepare(
                `INSERT INTO api_keys (id, name, key_hash, scopes_json)
      VALUES (?, ?, ?, ?)`
            )
            .run(keyID, name.trim(), hashSecret(key), JSON.stringify(normalizedScopes));
        return { id: keyID, key, scopes: normalizedScopes };
    }

    revokeAPIKey(keyID: string): boolean {
        const result = this.connection
            .prepare("UPDATE api_keys SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
            .run(now(), keyID);
        return result.changes > 0;
    }

    authenticateAPIKey(key: string): { scopes: string[] } | null {
        const row = this.connection
            .prepare("SELECT scopes_json FROM api_keys WHERE key_hash = ? AND revoked_at IS NULL")
            .get(hashSecret(key)) as { scopes_json: string } | undefined;
        return row ? { scopes: JSON.parse(row.scopes_json) as string[] } : null;
    }

    createPairingSession(ttlSeconds = 300): { token: string; expiresAt: string } {
        const token = `pbp_${crypto.randomBytes(32).toString("base64url")}`;
        const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
        this.connection
            .prepare(
                `
      INSERT INTO pairing_sessions (token_hash, expires_at)
      VALUES (?, ?)
    `
            )
            .run(hashSecret(token), expiresAt);
        return { expiresAt, token };
    }

    pairDevice(input: {
        token: string;
        displayName: string;
        appVersion: string;
        protocolVersion: number;
        capabilities: string[];
    }): { deviceID: string; deviceSecret: string } {
        const session = this.connection
            .prepare("SELECT expires_at, consumed FROM pairing_sessions WHERE token_hash = ?")
            .get(hashSecret(input.token)) as { expires_at: string; consumed: number } | undefined;
        if (!session) throw new PairingError("PAIRING_INVALID", 404);
        if (session.consumed) throw new PairingError("PAIRING_ALREADY_USED", 409);
        if (new Date(session.expires_at).getTime() <= Date.now()) throw new PairingError("PAIRING_EXPIRED", 410);
        if (input.protocolVersion !== 1) throw new PairingError("PROTOCOL_VERSION_UNSUPPORTED", 400);
        const capabilities = [...new Set(input.capabilities)].sort();
        if (capabilities.some(capability => !DEVICE_CAPABILITIES.has(capability))) {
            throw new PairingError("CAPABILITY_UNSUPPORTED", 400);
        }

        const deviceID = id("device");
        const deviceSecret = `pbd_${crypto.randomBytes(32).toString("base64url")}`;
        const createdAt = now();
        const transaction = this.connection.transaction(() => {
            this.connection
                .prepare(
                    `
        INSERT INTO devices (id, display_name, app_version, capabilities_json, paired_at)
        VALUES (?, ?, ?, ?, ?)
      `
                )
                .run(deviceID, input.displayName, input.appVersion, JSON.stringify(capabilities), createdAt);
            this.connection
                .prepare(`INSERT INTO device_credentials (device_id, secret_hash) VALUES (?, ?)`)
                .run(deviceID, hashSecret(deviceSecret));
            this.connection
                .prepare("UPDATE pairing_sessions SET consumed = 1 WHERE token_hash = ?")
                .run(hashSecret(input.token));
        });
        transaction();
        return { deviceID, deviceSecret };
    }

    authenticateDevice(deviceID: string, secret: string): boolean {
        const row = this.connection
            .prepare(
                `
      SELECT dc.secret_hash FROM device_credentials dc
      JOIN devices d ON d.id = dc.device_id
      WHERE dc.device_id = ? AND d.revoked_at IS NULL
    `
            )
            .get(deviceID) as { secret_hash: string } | undefined;
        return row ? safeEqual(row.secret_hash, hashSecret(secret)) : false;
    }

    touchDevice(deviceID: string): void {
        this.connection.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?").run(now(), deviceID);
    }

    listDevices(): DeviceRecord[] {
        return this.connection
            .prepare("SELECT * FROM devices WHERE revoked_at IS NULL ORDER BY paired_at DESC")
            .all() as DeviceRecord[];
    }

    getDevice(deviceID: string): DeviceRecord | undefined {
        return this.connection.prepare("SELECT * FROM devices WHERE id = ? AND revoked_at IS NULL").get(deviceID) as
            DeviceRecord | undefined;
    }

    revokeDevice(deviceID: string): boolean {
        const timestamp = now();
        const transaction = this.connection.transaction(() => {
            const result = this.connection
                .prepare("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
                .run(timestamp, deviceID);
            return result.changes > 0;
        });
        return transaction();
    }
}

export class PairingError extends Error {
    constructor(
        readonly code: string,
        readonly status: number
    ) {
        super(code);
    }
}

export const hashSecret = (secret: string): string => crypto.createHash("sha256").update(secret, "utf8").digest("hex");

export const id = (prefix: string): string => `${prefix}_${crypto.randomUUID().replaceAll("-", "")}`;

export const now = (): string => new Date().toISOString();

const safeEqual = (left: string, right: string): boolean => {
    const leftBuffer = Buffer.from(left);
    const rightBuffer = Buffer.from(right);
    return leftBuffer.length === rightBuffer.length && crypto.timingSafeEqual(leftBuffer, rightBuffer);
};

const DEVICE_CAPABILITIES = new Set([
    "albums.create",
    "albums.membership.write",
    "assets.thumbnail.read",
    "library.albums.read",
    "library.metadata.read",
]);
