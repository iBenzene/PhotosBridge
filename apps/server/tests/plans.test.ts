import assert from "node:assert/strict";
import crypto from "node:crypto";
import { afterEach, beforeEach, describe, it } from "node:test";
import { PhotosBridgeDatabase } from "../src/database.js";
import { PlanError, PlanService } from "../src/plans.js";

let database: PhotosBridgeDatabase;
let plans: PlanService;
let deviceID: string;

beforeEach(() => {
    database = new PhotosBridgeDatabase(":memory:");
    database.seedAdminKey("admin-test-key");
    const session = database.createPairingSession();
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
            asset_ids: [" b ", "a", "b"],
            device_id: deviceID,
            idempotency_key: " same-request ",
            summary: " test ",
            target_album: { create_if_missing: true, name: " Test " },
        };
        const first = plans.create(input);
        const second = plans.create(input);
        assert.equal(first.plan_id, second.plan_id);
        assert.equal(first.operation, "album_members.add");
        assert.deepEqual(first.asset_ids, ["a", "b"]);
        assert.equal(first.summary, "test");
        assert.equal(first.target_album?.name, "Test");
        assert.equal("status" in first, false);
        assert.equal("expires_at" in first, false);
    });

    it("rejects unknown operation types", () => {
        assert.throws(
            () =>
                plans.create({
                    asset_ids: ["a"],
                    device_id: deviceID,
                    idempotency_key: "unsupported-operation",
                    operation: "album.delete",
                    summary: "test",
                    target_album: { create_if_missing: false, name: "Test" },
                }),
            (error: unknown) => error instanceof PlanError && error.code === "OPERATION_UNSUPPORTED"
        );
    });

    it("rejects changed content under the same idempotency key", () => {
        const base = {
            asset_ids: ["a"],
            device_id: deviceID,
            idempotency_key: "conflict",
            summary: "test",
            target_album: { create_if_missing: true, name: "Test" },
        };
        plans.create(base);
        assert.throws(
            () => plans.create({ ...base, asset_ids: ["b"] }),
            (error: unknown) => error instanceof PlanError && error.code === "IDEMPOTENCY_CONFLICT"
        );
    });

    it("creates a first-class removal plan", () => {
        const plan = plans.create({
            asset_ids: ["asset-b", "asset-a", "asset-b"],
            device_id: deviceID,
            idempotency_key: "remove-members",
            operation: "album_members.remove",
            source_album: { id: "album-source", name: " Source " },
            summary: "remove",
        });

        assert.equal(plan.operation, "album_members.remove");
        assert.deepEqual(plan.source_album, { id: "album-source", name: "Source" });
        assert.equal(plan.target_album, undefined);
        assert.deepEqual(plan.asset_ids, ["asset-a", "asset-b"]);
        assert.throws(
            () =>
                plans.create({
                    asset_ids: ["asset-a"],
                    device_id: deviceID,
                    idempotency_key: "remove-with-target",
                    operation: "album_members.remove",
                    source_album: { id: "album-source", name: "Source" },
                    summary: "remove",
                    target_album: { create_if_missing: false, name: "Target" },
                }),
            (error: unknown) => error instanceof PlanError && error.code === "INVALID_REQUEST"
        );
    });

    it("creates an atomic move only between existing distinct albums", () => {
        const plan = plans.create({
            asset_ids: ["asset-a"],
            device_id: deviceID,
            idempotency_key: "move-members",
            operation: "album_members.move",
            source_album: { id: "album-source", name: "Source" },
            summary: "move",
            target_album: { create_if_missing: false, id: "album-target", name: "Target" },
        });

        assert.equal(plan.operation, "album_members.move");
        assert.equal(plan.source_album?.id, "album-source");
        assert.equal(plan.target_album?.id, "album-target");
        assert.throws(
            () =>
                plans.create({
                    asset_ids: ["asset-a"],
                    device_id: deviceID,
                    idempotency_key: "move-create",
                    operation: "album_members.move",
                    source_album: { id: "album-source", name: "Source" },
                    summary: "move",
                    target_album: { create_if_missing: true, name: "Target" },
                }),
            (error: unknown) => error instanceof PlanError && error.code === "ATOMIC_MOVE_REQUIRES_EXISTING_TARGET"
        );
        assert.throws(
            () =>
                plans.create({
                    asset_ids: ["asset-a"],
                    device_id: deviceID,
                    idempotency_key: "move-same",
                    operation: "album_members.move",
                    source_album: { id: "album-source", name: "Source" },
                    summary: "move",
                    target_album: { create_if_missing: false, id: "album-source", name: "Source" },
                }),
            (error: unknown) => error instanceof PlanError && error.code === "MOVE_SOURCE_EQUALS_TARGET"
        );
    });

    it("replays a legacy plan without changing its hash shape", () => {
        const legacyContentHash = crypto
            .createHash("sha256")
            .update(
                JSON.stringify({
                    asset_ids: ["a"],
                    device_id: deviceID,
                    summary: "test",
                    target_album: { create_if_missing: true, name: "Test" },
                })
            )
            .digest("hex");
        database.connection
            .prepare(
                `
            INSERT INTO plans
                (id, device_id, idempotency_key, summary, target_album_json, asset_ids_json, content_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        `
            )
            .run(
                "plan_legacy",
                deviceID,
                "legacy-request",
                "test",
                JSON.stringify({ create_if_missing: true, name: "Test" }),
                JSON.stringify(["a"]),
                legacyContentHash,
                "2026-07-29T12:00:00Z"
            );

        const plan = plans.create({
            asset_ids: ["a"],
            device_id: deviceID,
            idempotency_key: "legacy-request",
            summary: "test",
            target_album: { create_if_missing: true, name: "Test" },
        });

        assert.equal(plan.plan_id, "plan_legacy");
        assert.equal(plan.operation, undefined);
    });

    it("retrieves an immutable plan without delivery state", () => {
        const plan = plans.create({
            asset_ids: ["asset-a"],
            device_id: deviceID,
            idempotency_key: "delivery-only",
            summary: "test",
            target_album: { create_if_missing: true, name: "Test" },
        });
        assert.deepEqual(plans.get(plan.plan_id), plan);
    });
});
