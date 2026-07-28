import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { PhotosBridgeDatabase } from "../src/database.js";
import { PlanError, PlanService } from "../src/plans.js";

let database: PhotosBridgeDatabase;
let plans: PlanService;
let deviceID: string;
let apiKeyID: string;

beforeEach(() => {
    database = new PhotosBridgeDatabase(":memory:");
    database.seedAdminKey("admin-test-key");
    apiKeyID = database.authenticateAPIKey("admin-test-key")!.id;
    const session = database.createPairingSession("https://bridge.test");
    deviceID = database.pairDevice({
        appVersion: "0.1.0",
        capabilities: ["albums.create", "albums.membership.write"],
        displayName: "iPhone",
        protocolVersion: 1,
        token: session.token,
    }).deviceID;
    plans = new PlanService(database);
});

afterEach(() => database.close());

describe("PlanService", () => {
    it("deduplicates assets and replays an identical idempotent request", () => {
        const input = {
            asset_ids: ["b", "a", "b"],
            device_id: deviceID,
            idempotency_key: "same-request",
            summary: "test",
            target_album: { create_if_missing: true, name: "Test" },
        };
        const first = plans.create(input, apiKeyID);
        const second = plans.create(input, apiKeyID);
        assert.equal(first.plan_id, second.plan_id);
        assert.deepEqual(first.asset_ids, ["a", "b"]);
        const ttl = new Date(first.expires_at).getTime() - Date.now();
        assert.ok(ttl > 6 * 24 * 60 * 60 * 1000);
        assert.ok(ttl <= 7 * 24 * 60 * 60 * 1000);
    });

    it("rejects changed content under the same idempotency key", () => {
        const base = {
            asset_ids: ["a"],
            device_id: deviceID,
            idempotency_key: "conflict",
            summary: "test",
            target_album: { create_if_missing: true, name: "Test" },
        };
        plans.create(base, apiKeyID);
        assert.throws(
            () => plans.create({ ...base, asset_ids: ["b"] }, apiKeyID),
            (error: unknown) => error instanceof PlanError && error.code === "IDEMPOTENCY_CONFLICT"
        );
    });

    it("undoes only asset memberships recorded for the completed batch", () => {
        const plan = plans.create(
            {
                asset_ids: ["existing", "new-a", "new-b"],
                device_id: deviceID,
                idempotency_key: "undo-source",
                summary: "test",
                target_album: { create_if_missing: true, name: "Test" },
            },
            apiKeyID
        );
        const prepared = plans.prepareApproval(plan.plan_id);
        plans.handleDeviceEvent("operation.executing", {
            operation_id: prepared.operation_id,
            plan_id: plan.plan_id,
        });
        plans.handleDeviceEvent("operation.completed", {
            added_asset_ids: ["new-a", "new-b"],
            album_id: "album_1",
            batch_id: "batch_safe",
            counts: { added: 2, failed: 0, missing: 0, requested: 3, skipped_existing: 1 },
            failures: [],
            operation_id: prepared.operation_id,
            plan_id: plan.plan_id,
        });

        const undo = plans.createUndo("batch_safe");
        assert.deepEqual(undo.asset_ids, ["new-a", "new-b"]);
        assert.equal(undo.asset_ids.includes("existing"), false);
        plans.handleDeviceEvent("undo.completed", {
            batch_id: "batch_safe",
            removed_asset_ids: ["new-a", "new-b"],
            undo_plan_id: undo.undo_plan_id,
        });
        assert.equal(plans.getUndo(undo.undo_plan_id)?.status, "completed");
        assert.equal(plans.createUndo("batch_safe").status, "completed");
    });
});
