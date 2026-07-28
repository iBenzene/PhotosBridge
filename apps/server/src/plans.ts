/**
 * @file plans.ts
 * @description Transfer plan execution, approval workflow, and task state management.
 * @author iBenzene
 */
import crypto from "node:crypto";
import type { PhotosBridgeDatabase } from "./database.js";
import { id, now } from "./database.js";

const DEFAULT_PLAN_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export type PlanInput = {
    device_id: string;
    idempotency_key: string;
    summary: string;
    target_album: { name: string; create_if_missing: boolean };
    asset_ids: string[];
};

export class PlanService {
    constructor(private readonly database: PhotosBridgeDatabase) {}

    create(input: PlanInput, requesterKeyID: string) {
        if (
            !input.device_id ||
            !input.idempotency_key ||
            !input.target_album?.name ||
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
        const assetIDs = [...new Set(input.asset_ids.map(String))].sort();
        if (assetIDs.length === 0 || assetIDs.length > 5000) throw new PlanError("PLAN_SIZE_INVALID", 400);
        const content = {
            asset_ids: assetIDs,
            device_id: input.device_id,
            summary: String(input.summary ?? ""),
            target_album: {
                create_if_missing: Boolean(input.target_album.create_if_missing),
                name: String(input.target_album.name),
            },
        };
        const contentHash = crypto.createHash("sha256").update(canonicalJSON(content)).digest("hex");
        const existing = this.database.connection
            .prepare("SELECT * FROM plans WHERE device_id = ? AND idempotency_key = ?")
            .get(input.device_id, input.idempotency_key) as Record<string, unknown> | undefined;
        if (existing) {
            if (existing.content_hash !== contentHash) throw new PlanError("IDEMPOTENCY_CONFLICT", 409);
            return this.present(existing);
        }
        const planID = id("plan");
        const timestamp = now();
        const expiresAt = new Date(Date.now() + DEFAULT_PLAN_TTL_MS).toISOString();
        this.database.connection
            .prepare(
                `
      INSERT INTO plans (id, device_id, idempotency_key, requester_key_id, summary, target_album_json,
        asset_ids_json, content_hash, status, created_at, expires_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'draft', ?, ?, ?)
    `
            )
            .run(
                planID,
                input.device_id,
                input.idempotency_key,
                requesterKeyID,
                content.summary,
                JSON.stringify(content.target_album),
                JSON.stringify(assetIDs),
                contentHash,
                timestamp,
                expiresAt,
                timestamp
            );
        this.database.audit(
            "plan.created",
            "api_key",
            requesterKeyID,
            { asset_count: assetIDs.length },
            { deviceID: input.device_id, planID }
        );
        return this.get(planID)!;
    }

    get(planID: string) {
        const row = this.database.connection.prepare("SELECT * FROM plans WHERE id = ?").get(planID) as
            Record<string, unknown> | undefined;
        return row ? this.present(row) : undefined;
    }

    prepareApproval(planID: string) {
        const plan = this.get(planID);
        if (!plan) throw new PlanError("PLAN_NOT_FOUND", 404);
        if (!["draft", "awaiting_device"].includes(plan.status)) throw new PlanError("PLAN_STATE_INVALID", 409);
        if (new Date(plan.expires_at).getTime() <= Date.now()) throw new PlanError("PLAN_EXPIRED", 410);
        let operation = this.database.connection.prepare("SELECT * FROM operations WHERE plan_id = ?").get(planID) as
            Record<string, unknown> | undefined;
        if (!operation) {
            const operationID = id("op");
            const timestamp = now();
            this.database.connection
                .prepare(
                    `INSERT INTO operations (id, plan_id, status, created_at, updated_at)
        VALUES (?, ?, 'awaiting_approval', ?, ?)`
                )
                .run(operationID, planID, timestamp, timestamp);
            operation = this.database.connection
                .prepare("SELECT * FROM operations WHERE id = ?")
                .get(operationID) as Record<string, unknown>;
        }
        this.setPlanStatus(planID, "awaiting_device");
        return { operation_id: String(operation.id), plan: this.get(planID)! };
    }

    markAwaitingApproval(planID: string): void {
        this.setPlanStatus(planID, "awaiting_approval");
    }
    cancel(planID: string): void {
        this.setPlanStatus(planID, "cancelled");
    }

    handleDeviceEvent(type: string, payload: unknown): void {
        const value = payload as Record<string, unknown>;
        const planID = String(value.plan_id ?? "");
        const operationID = String(value.operation_id ?? "");
        this.database.audit(
            type,
            "device",
            null,
            {},
            { operationID: operationID || undefined, planID: planID || undefined }
        );
        if (type === "plan.rejected") this.setPlanStatus(planID, "rejected");
        if (type === "operation.executing") {
            this.setPlanStatus(planID, "executing");
            this.setOperation(operationID, "executing");
        }
        if (type === "operation.unknown") {
            this.setPlanStatus(planID, "unknown");
            this.setOperation(operationID, "unknown");
        }
        if (type === "operation.completed") {
            const status =
                Number((value.counts as Record<string, unknown>)?.failed ?? 0) > 0
                    ? "completed_with_errors"
                    : "completed";
            const batchID = String(value.batch_id ?? id("batch"));
            const transaction = this.database.connection.transaction(() => {
                this.database.connection
                    .prepare(
                        "UPDATE operations SET status = ?, batch_id = ?, counts_json = ?, failures_json = ?, updated_at = ? WHERE id = ?"
                    )
                    .run(
                        status,
                        batchID,
                        JSON.stringify(value.counts ?? {}),
                        JSON.stringify(value.failures ?? []),
                        now(),
                        operationID
                    );
                this.setPlanStatus(planID, status);
                const insert = this.database.connection.prepare(
                    "INSERT OR IGNORE INTO batch_items (batch_id, asset_id, target_album_id) VALUES (?, ?, ?)"
                );
                for (const assetID of (value.added_asset_ids as string[] | undefined) ?? []) {
                    insert.run(batchID, assetID, String(value.album_id ?? ""));
                }
            });
            transaction();
        }
        if (type === "undo.rejected") {
            this.database.connection
                .prepare("UPDATE undo_plans SET status = 'rejected', updated_at = ? WHERE id = ?")
                .run(now(), String(value.undo_plan_id ?? ""));
        }
        if (type === "undo.completed") {
            const undoID = String(value.undo_plan_id ?? "");
            const removed = (value.removed_asset_ids as string[] | undefined) ?? [];
            const transaction = this.database.connection.transaction(() => {
                this.database.connection
                    .prepare("UPDATE undo_plans SET status = 'completed', updated_at = ? WHERE id = ?")
                    .run(now(), undoID);
                const statement = this.database.connection.prepare(
                    "UPDATE batch_items SET undone_at = ? WHERE batch_id = ? AND asset_id = ? AND undone_at IS NULL"
                );
                for (const assetID of removed) statement.run(now(), String(value.batch_id ?? ""), assetID);
            });
            transaction();
        }
    }

    getOperation(operationID: string) {
        const row = this.database.connection.prepare("SELECT * FROM operations WHERE id = ?").get(operationID) as
            Record<string, unknown> | undefined;
        if (!row) return undefined;
        return {
            batch_id: row.batch_id,
            counts: row.counts_json ? JSON.parse(String(row.counts_json)) : null,
            created_at: row.created_at,
            failures: row.failures_json ? JSON.parse(String(row.failures_json)) : [],
            operation_id: row.id,
            plan_id: row.plan_id,
            status: row.status,
            updated_at: row.updated_at,
        };
    }

    createUndo(batchID: string) {
        const existing = this.database.connection
            .prepare("SELECT * FROM undo_plans WHERE batch_id = ?")
            .get(batchID) as Record<string, unknown> | undefined;
        if (existing) return this.presentUndo(existing);
        const items = this.database.connection
            .prepare(
                `
      SELECT bi.asset_id, bi.target_album_id, p.device_id
      FROM batch_items bi JOIN operations o ON o.batch_id = bi.batch_id
      JOIN plans p ON p.id = o.plan_id
      WHERE bi.batch_id = ? AND bi.undone_at IS NULL
    `
            )
            .all(batchID) as Array<{ asset_id: string; target_album_id: string; device_id: string }>;
        if (items.length === 0) throw new PlanError("BATCH_NOT_UNDOABLE", 409);
        const undoID = id("undo");
        const assetIDs = items.map(item => item.asset_id).sort();
        const content = { asset_ids: assetIDs, batch_id: batchID, target_album_id: items[0]!.target_album_id };
        const hash = crypto.createHash("sha256").update(canonicalJSON(content)).digest("hex");
        const timestamp = now();
        this.database.connection
            .prepare(
                `INSERT INTO undo_plans
      (id, batch_id, device_id, target_album_id, asset_ids_json, content_hash, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 'awaiting_device', ?, ?)`
            )
            .run(
                undoID,
                batchID,
                items[0]!.device_id,
                items[0]!.target_album_id,
                JSON.stringify(assetIDs),
                hash,
                timestamp,
                timestamp
            );
        return this.getUndo(undoID)!;
    }

    getUndo(undoID: string) {
        const row = this.database.connection.prepare("SELECT * FROM undo_plans WHERE id = ?").get(undoID) as
            Record<string, unknown> | undefined;
        return row ? this.presentUndo(row) : undefined;
    }

    markUndoAwaitingApproval(undoID: string): void {
        this.database.connection
            .prepare("UPDATE undo_plans SET status = 'awaiting_approval', updated_at = ? WHERE id = ?")
            .run(now(), undoID);
    }

    private setPlanStatus(planID: string, status: string): void {
        this.database.connection
            .prepare("UPDATE plans SET status = ?, updated_at = ? WHERE id = ?")
            .run(status, now(), planID);
    }
    private setOperation(operationID: string, status: string): void {
        this.database.connection
            .prepare("UPDATE operations SET status = ?, updated_at = ? WHERE id = ?")
            .run(status, now(), operationID);
    }
    private present(row: Record<string, unknown>) {
        return {
            asset_ids: JSON.parse(String(row.asset_ids_json)) as string[],
            content_hash: String(row.content_hash),
            created_at: String(row.created_at),
            device_id: String(row.device_id),
            expires_at: String(row.expires_at),
            idempotency_key: String(row.idempotency_key),
            plan_id: String(row.id),
            status: String(row.status),
            summary: String(row.summary),
            target_album: JSON.parse(String(row.target_album_json)),
        };
    }
    private presentUndo(row: Record<string, unknown>) {
        return {
            asset_ids: JSON.parse(String(row.asset_ids_json)) as string[],
            batch_id: String(row.batch_id),
            content_hash: String(row.content_hash),
            created_at: String(row.created_at),
            device_id: String(row.device_id),
            status: String(row.status),
            target_album_id: String(row.target_album_id),
            undo_plan_id: String(row.id),
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
