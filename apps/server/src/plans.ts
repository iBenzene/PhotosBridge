/**
 * @file plans.ts
 * @description Immutable plan creation and retrieval.
 * @author iBenzene
 */
import crypto from "node:crypto";
import type { PhotosBridgeDatabase } from "./database.js";
import { id, now } from "./database.js";

export type PlanOperation = "album_members.add" | "album_members.remove" | "album_members.move";

export type AlbumReference = { id: string; name: string };
export type TargetAlbum = { id?: string; name: string; create_if_missing: boolean };

export type PlanInput = {
    device_id: string;
    idempotency_key: string;
    operation?: string;
    summary: string;
    source_album?: AlbumReference;
    target_album?: TargetAlbum;
    asset_ids: string[];
};

export type PresentedPlan = {
    asset_ids: string[];
    content_hash: string;
    created_at: string;
    device_id: string;
    operation?: PlanOperation;
    plan_id: string;
    summary: string;
    source_album?: AlbumReference;
    target_album?: TargetAlbum;
};

export class PlanService {
    constructor(private readonly database: PhotosBridgeDatabase) {}

    create(input: PlanInput): PresentedPlan {
        if (
            typeof input.device_id !== "string" ||
            typeof input.idempotency_key !== "string" ||
            typeof input.summary !== "string" ||
            !Array.isArray(input.asset_ids)
        ) {
            throw new PlanError("INVALID_REQUEST", 400);
        }
        const operation = input.operation ?? "album_members.add";
        if (!isPlanOperation(operation)) throw new PlanError("OPERATION_UNSUPPORTED", 400);
        if (!this.database.getDevice(input.device_id)) throw new PlanError("DEVICE_NOT_FOUND", 404);
        const device = this.database.getDevice(input.device_id)!;
        const capabilities = new Set(JSON.parse(device.capabilities_json) as string[]);
        if (!capabilities.has("albums.membership.write")) throw new PlanError("CAPABILITY_NOT_GRANTED", 403);

        const idempotencyKey = input.idempotency_key.trim();
        const summary = input.summary.trim();
        if (!idempotencyKey || idempotencyKey.length > 200 || summary.length > 500) {
            throw new PlanError("INVALID_REQUEST", 400);
        }
        if (input.asset_ids.some(value => typeof value !== "string")) throw new PlanError("INVALID_REQUEST", 400);
        const rawAssetIDs = input.asset_ids.map(value => value.trim());
        if (rawAssetIDs.some(assetID => !assetID)) throw new PlanError("INVALID_REQUEST", 400);
        const assetIDs = [...new Set(rawAssetIDs)].sort();
        if (assetIDs.length === 0 || assetIDs.length > 5000) throw new PlanError("PLAN_SIZE_INVALID", 400);
        if (
            (operation === "album_members.add" && input.source_album !== undefined) ||
            (operation === "album_members.remove" && input.target_album !== undefined)
        ) {
            throw new PlanError("INVALID_REQUEST", 400);
        }

        const sourceAlbum = operation === "album_members.add" ? undefined : normalizeSourceAlbum(input.source_album);
        const targetAlbum = operation === "album_members.remove" ? undefined : normalizeTargetAlbum(input.target_album);
        if (operation === "album_members.add" && targetAlbum!.create_if_missing && !capabilities.has("albums.create")) {
            throw new PlanError("CAPABILITY_NOT_GRANTED", 403);
        }
        if (operation === "album_members.move" && (!targetAlbum!.id || targetAlbum!.create_if_missing)) {
            throw new PlanError("ATOMIC_MOVE_REQUIRES_EXISTING_TARGET", 400);
        }
        if (operation === "album_members.move" && sourceAlbum!.id === targetAlbum!.id) {
            throw new PlanError("MOVE_SOURCE_EQUALS_TARGET", 400);
        }

        const content = compactPlanContent({
            asset_ids: assetIDs,
            device_id: input.device_id,
            operation,
            source_album: sourceAlbum,
            summary,
            target_album: targetAlbum,
        });
        const contentHash = hashCanonical(content);
        const legacyContentHash =
            operation === "album_members.add"
                ? hashCanonical({
                      asset_ids: assetIDs,
                      device_id: input.device_id,
                      summary,
                      target_album: targetAlbum,
                  })
                : undefined;
        const existing = this.database.connection
            .prepare("SELECT * FROM plans WHERE device_id = ? AND idempotency_key = ?")
            .get(input.device_id, idempotencyKey) as Record<string, unknown> | undefined;
        if (existing) {
            if (existing.content_hash !== contentHash && existing.content_hash !== legacyContentHash) {
                throw new PlanError("IDEMPOTENCY_CONFLICT", 409);
            }
            return presentStoredPlan(existing);
        }

        const planID = id("plan");
        const timestamp = now();
        this.database.connection
            .prepare(
                `
                INSERT INTO plans
                    (id, device_id, idempotency_key, operation, summary, source_album_json,
                     target_album_json, asset_ids_json, content_hash, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            `
            )
            .run(
                planID,
                input.device_id,
                idempotencyKey,
                operation,
                summary,
                sourceAlbum ? JSON.stringify(sourceAlbum) : null,
                JSON.stringify(targetAlbum ?? {}),
                JSON.stringify(assetIDs),
                contentHash,
                timestamp
            );
        return this.get(planID)!;
    }

    get(planID: string): PresentedPlan | undefined {
        const row = this.database.connection.prepare("SELECT * FROM plans WHERE id = ?").get(planID) as
            Record<string, unknown> | undefined;
        return row ? presentStoredPlan(row) : undefined;
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

export const presentStoredPlan = (row: Record<string, unknown>): PresentedPlan => {
    const base = {
        asset_ids: JSON.parse(String(row.asset_ids_json)) as string[],
        content_hash: String(row.content_hash),
        created_at: String(row.created_at),
        device_id: String(row.device_id),
        plan_id: String(row.id ?? row.plan_id),
        summary: String(row.summary),
    };
    const storedOperation =
        typeof row.operation === "string" && isPlanOperation(row.operation) ? row.operation : undefined;
    const sourceAlbum = row.source_album_json
        ? (JSON.parse(String(row.source_album_json)) as AlbumReference)
        : undefined;
    const storedTarget = JSON.parse(String(row.target_album_json)) as Partial<TargetAlbum>;
    const targetAlbum = typeof storedTarget.name === "string" ? (storedTarget as TargetAlbum) : undefined;
    if (storedOperation) {
        return compactPlanContent({
            ...base,
            operation: storedOperation,
            source_album: sourceAlbum,
            target_album: targetAlbum,
        });
    }
    const typedAdd = compactPlanContent({
        ...base,
        operation: "album_members.add" as const,
        target_album: targetAlbum,
    });
    return hashCanonical(typedAddWithoutEnvelope(typedAdd)) === base.content_hash
        ? typedAdd
        : { ...base, target_album: targetAlbum };
};

const typedAddWithoutEnvelope = (plan: PresentedPlan) => ({
    asset_ids: plan.asset_ids,
    device_id: plan.device_id,
    operation: plan.operation,
    summary: plan.summary,
    target_album: plan.target_album,
});

const compactPlanContent = <T extends Record<string, unknown>>(value: T): T =>
    Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as T;

const normalizeSourceAlbum = (album: AlbumReference | undefined): AlbumReference => {
    if (typeof album?.id !== "string" || typeof album.name !== "string") throw new PlanError("INVALID_REQUEST", 400);
    const normalized = { id: album.id.trim(), name: album.name.trim() };
    if (!normalized.id || !normalized.name || normalized.name.length > 255) throw new PlanError("INVALID_REQUEST", 400);
    return normalized;
};

const normalizeTargetAlbum = (album: TargetAlbum | undefined): TargetAlbum => {
    if (typeof album?.name !== "string" || typeof album.create_if_missing !== "boolean") {
        throw new PlanError("INVALID_REQUEST", 400);
    }
    const normalized = {
        ...(typeof album.id === "string" ? { id: album.id.trim() } : {}),
        create_if_missing: album.create_if_missing,
        name: album.name.trim(),
    };
    if (!normalized.name || normalized.name.length > 255 || ("id" in normalized && !normalized.id)) {
        throw new PlanError("INVALID_REQUEST", 400);
    }
    return normalized;
};

const isPlanOperation = (value: string): value is PlanOperation =>
    ["album_members.add", "album_members.remove", "album_members.move"].includes(value);

const hashCanonical = (value: unknown): string =>
    crypto.createHash("sha256").update(canonicalJSON(value)).digest("hex");

const canonicalJSON = (value: unknown): string => {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object)
        .sort()
        .map(key => `${JSON.stringify(key)}:${canonicalJSON(object[key])}`)
        .join(",")}}`;
};
