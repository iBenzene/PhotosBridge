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
    protocol_version: number;
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
      INSERT INTO api_keys (id, name, key_hash, scopes_json, created_at)
      VALUES (?, ?, ?, ?, ?)
    `
            )
            .run(
                id("key"),
                "bootstrap-admin",
                hashSecret(key),
                JSON.stringify(["admin", "library.read", "plans.write"]),
                now()
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
                `INSERT INTO api_keys (id, name, key_hash, scopes_json, created_at)
      VALUES (?, ?, ?, ?, ?)`
            )
            .run(keyID, name.trim(), hashSecret(key), JSON.stringify(normalizedScopes), now());
        this.audit("api_key.created", "api_key", keyID, { name: name.trim(), scopes: normalizedScopes });
        return { id: keyID, key, scopes: normalizedScopes };
    }

    revokeAPIKey(keyID: string): boolean {
        const result = this.connection
            .prepare("UPDATE api_keys SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
            .run(now(), keyID);
        if (result.changes > 0) this.audit("api_key.revoked", "api_key", keyID, {});
        return result.changes > 0;
    }

    authenticateAPIKey(key: string): { id: string; scopes: string[] } | null {
        const row = this.connection
            .prepare("SELECT id, scopes_json FROM api_keys WHERE key_hash = ? AND revoked_at IS NULL")
            .get(hashSecret(key)) as { id: string; scopes_json: string } | undefined;
        return row ? { id: row.id, scopes: JSON.parse(row.scopes_json) as string[] } : null;
    }

    createPairingSession(serverURL: string, ttlSeconds = 300): { id: string; token: string; expiresAt: string } {
        const sessionID = id("pair");
        const token = `pbp_${crypto.randomBytes(32).toString("base64url")}`;
        const createdAt = now();
        const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
        this.connection
            .prepare(
                `
      INSERT INTO pairing_sessions (id, token_hash, server_url, expires_at, created_at)
      VALUES (?, ?, ?, ?, ?)
    `
            )
            .run(sessionID, hashSecret(token), serverURL, expiresAt, createdAt);
        return { expiresAt, id: sessionID, token };
    }

    pairDevice(input: {
        token: string;
        displayName: string;
        appVersion: string;
        protocolVersion: number;
        capabilities: string[];
    }): { deviceID: string; deviceSecret: string } {
        const session = this.connection
            .prepare("SELECT id, expires_at, consumed_at FROM pairing_sessions WHERE token_hash = ?")
            .get(hashSecret(input.token)) as { id: string; expires_at: string; consumed_at: string | null } | undefined;
        if (!session) throw new PairingError("PAIRING_INVALID", 404);
        if (session.consumed_at) throw new PairingError("PAIRING_ALREADY_USED", 409);
        if (new Date(session.expires_at).getTime() <= Date.now()) throw new PairingError("PAIRING_EXPIRED", 410);
        if (input.protocolVersion !== 1) throw new PairingError("PROTOCOL_VERSION_UNSUPPORTED", 400);

        const deviceID = id("device");
        const deviceSecret = `pbd_${crypto.randomBytes(32).toString("base64url")}`;
        const createdAt = now();
        const transaction = this.connection.transaction(() => {
            this.connection
                .prepare(
                    `
        INSERT INTO devices (id, display_name, app_version, protocol_version, capabilities_json, paired_at)
        VALUES (?, ?, ?, ?, ?, ?)
      `
                )
                .run(
                    deviceID,
                    input.displayName,
                    input.appVersion,
                    input.protocolVersion,
                    JSON.stringify(input.capabilities),
                    createdAt
                );
            this.connection
                .prepare(
                    `
        INSERT INTO device_credentials (device_id, secret_hash, created_at) VALUES (?, ?, ?)
      `
                )
                .run(deviceID, hashSecret(deviceSecret), createdAt);
            this.connection
                .prepare("UPDATE pairing_sessions SET consumed_at = ? WHERE id = ?")
                .run(createdAt, session.id);
        });
        transaction();
        return { deviceID, deviceSecret };
    }

    authenticateDevice(deviceID: string, secret: string): boolean {
        const row = this.connection
            .prepare(
                `
      SELECT secret_hash FROM device_credentials
      WHERE device_id = ? AND revoked_at IS NULL
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
            this.connection
                .prepare("UPDATE device_credentials SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL")
                .run(timestamp, deviceID);
            return result.changes > 0;
        });
        return transaction();
    }

    audit(
        kind: string,
        actorType: string,
        actorID: string | null,
        details: Record<string, unknown>,
        links: {
            deviceID?: string;
            planID?: string;
            operationID?: string;
        } = {}
    ): void {
        this.connection
            .prepare(
                `INSERT INTO audit_events
      (id, kind, actor_type, actor_id, device_id, plan_id, operation_id, details_json, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
            )
            .run(
                id("audit"),
                kind,
                actorType,
                actorID,
                links.deviceID ?? null,
                links.planID ?? null,
                links.operationID ?? null,
                JSON.stringify(details),
                now()
            );
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
