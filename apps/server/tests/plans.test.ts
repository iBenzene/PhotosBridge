import assert from "node:assert/strict";
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
        assert.deepEqual(first.asset_ids, ["a", "b"]);
        assert.equal(first.summary, "test");
        assert.equal(first.target_album.name, "Test");
        assert.equal("status" in first, false);
        assert.equal("expires_at" in first, false);
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
