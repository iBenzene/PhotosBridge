/**
 * @file plans.ts
 * @description Immutable plan creation and retrieval.
 * @author iBenzene
 */
import crypto from "node:crypto";
import type { PhotosBridgeDatabase } from "./database.js";
import { id, now } from "./database.js";

export type PlanInput = {
    device_id: string;
    idempotency_key: string;
    summary: string;
    target_album: { name: string; create_if_missing: boolean };
    asset_ids: string[];
};

export class PlanService {
    constructor(private readonly database: PhotosBridgeDatabase) {}

    create(input: PlanInput) {
        if (
            typeof input.device_id !== "string" ||
            typeof input.idempotency_key !== "string" ||
            typeof input.summary !== "string" ||
            typeof input.target_album?.name !== "string" ||
            typeof input.target_album?.create_if_missing !== "boolean" ||
            !Array.isArray(input.asset_ids)
        ) {
            throw new PlanError("INVALID_REQUEST", 400);
        }
        if (!this.database.getDevice(input.device_id)) throw new PlanError("DEVICE_NOT_FOUND", 404);
        const device = this.database.getDevice(input.device_id)!;
        const capabilities = new Set(JSON.parse(device.capabilities_json) as string[]);
        if (!capabilities.has("albums.membership.write")) throw new PlanError("CAPABILITY_NOT_GRANTED", 403);
        if (input.target_album?.create_if_missing && !capabilities.has("albums.create")) {
            throw new PlanError("CAPABILITY_NOT_GRANTED", 403);
        }
        const idempotencyKey = String(input.idempotency_key).trim();
        const summary = String(input.summary ?? "").trim();
        const targetAlbumName = String(input.target_album.name).trim();
        if (!idempotencyKey || idempotencyKey.length > 200 || !targetAlbumName || targetAlbumName.length > 255) {
            throw new PlanError("INVALID_REQUEST", 400);
        }
        if (summary.length > 500) throw new PlanError("INVALID_REQUEST", 400);
        if (input.asset_ids.some(value => typeof value !== "string")) throw new PlanError("INVALID_REQUEST", 400);
        const rawAssetIDs = input.asset_ids.map(value => value.trim());
        if (rawAssetIDs.some(assetID => !assetID)) throw new PlanError("INVALID_REQUEST", 400);
        const assetIDs = [...new Set(rawAssetIDs)].sort();
        if (assetIDs.length === 0 || assetIDs.length > 5000) throw new PlanError("PLAN_SIZE_INVALID", 400);
        const content = {
            asset_ids: assetIDs,
            device_id: input.device_id,
            summary,
            target_album: {
                create_if_missing: input.target_album.create_if_missing,
                name: targetAlbumName,
            },
        };
        const contentHash = crypto.createHash("sha256").update(canonicalJSON(content)).digest("hex");
        const existing = this.database.connection
            .prepare("SELECT * FROM plans WHERE device_id = ? AND idempotency_key = ?")
            .get(input.device_id, idempotencyKey) as Record<string, unknown> | undefined;
        if (existing) {
            if (existing.content_hash !== contentHash) throw new PlanError("IDEMPOTENCY_CONFLICT", 409);
            return this.present(existing);
        }
        const planID = id("plan");
        const timestamp = now();
        this.database.connection
            .prepare(
                `
      INSERT INTO plans
        (id, device_id, idempotency_key, summary, target_album_json, asset_ids_json, content_hash, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `
            )
            .run(
                planID,
                input.device_id,
                idempotencyKey,
                content.summary,
                JSON.stringify(content.target_album),
                JSON.stringify(assetIDs),
                contentHash,
                timestamp
            );
        return this.get(planID)!;
    }

    get(planID: string) {
        const row = this.database.connection.prepare("SELECT * FROM plans WHERE id = ?").get(planID) as
            Record<string, unknown> | undefined;
        return row ? this.present(row) : undefined;
    }

    private present(row: Record<string, unknown>) {
        return {
            asset_ids: JSON.parse(String(row.asset_ids_json)) as string[],
            content_hash: String(row.content_hash),
            created_at: String(row.created_at),
            device_id: String(row.device_id),
            plan_id: String(row.id),
            summary: String(row.summary),
            target_album: JSON.parse(String(row.target_album_json)),
        };
    }
}

export class PlanError extends Error {
    constructor(
        readonly code: string,
        readonly status: number
    ) {
        super(code);
    }
}

const canonicalJSON = (value: unknown): string => {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object)
        .sort()
        .map(key => `${JSON.stringify(key)}:${canonicalJSON(object[key])}`)
        .join(",")}}`;
};
