import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import request from "supertest";
import { createApp } from "../src/app.js";
import { PhotosBridgeDatabase } from "../src/database.js";
import { DeviceHub } from "../src/device-hub.js";

const adminKey = "test-admin-key-with-enough-entropy";
let database: PhotosBridgeDatabase;
let hub: DeviceHub;

beforeEach(() => {
    database = new PhotosBridgeDatabase(":memory:");
    database.seedAdminKey(adminKey);
    hub = new DeviceHub(database);
});

afterEach(() => database.close());

const app = () =>
    createApp({
        config: { adminKey, databasePath: ":memory:", port: 0, publicBaseURL: "https://bridge.test" },
        database,
        hub,
    });

describe("Photos Bridge Server", () => {
    it("reports version and protocol health without authentication", async () => {
        const response = await request(app()).get("/health").expect(200);
        assert.equal(response.body.version, "0.1.0");
        assert.equal(response.body.protocol_version, 1);
    });

    it("protects device APIs", async () => {
        await request(app()).get("/api/v1/devices").expect(401);
    });

    it("pairs a device exactly once and lists it", async () => {
        const pairing = await request(app())
            .post("/api/v1/pairing-sessions")
            .set("Authorization", `Bearer ${adminKey}`)
            .expect(201);

        const body = {
            app_version: "0.1.0",
            capabilities: ["library.metadata.read"],
            display_name: "Test iPhone",
            pairing_token: pairing.body.pairing_token,
            protocol_version: 1,
        };
        const paired = await request(app()).post("/device/v1/pair").send(body).expect(201);
        assert.match(paired.body.device_id, /^device_/);
        assert.match(paired.body.device_secret, /^pbd_/);

        const duplicate = await request(app()).post("/device/v1/pair").send(body).expect(409);
        assert.equal(duplicate.body.error.code, "PAIRING_ALREADY_USED");

        const devices = await request(app())
            .get("/api/v1/devices")
            .set("Authorization", `Bearer ${adminKey}`)
            .expect(200);
        assert.equal(devices.body.devices.length, 1);
        assert.equal(devices.body.devices[0].display_name, "Test iPhone");
        assert.equal(devices.body.devices[0].online, false);
    });

    it("returns a stable offline error for bridge reads", async () => {
        const session = database.createPairingSession("https://bridge.test");
        const paired = database.pairDevice({
            appVersion: "0.1.0",
            capabilities: ["library.metadata.read"],
            displayName: "Offline iPad",
            protocolVersion: 1,
            token: session.token,
        });
        const response = await request(app())
            .get(`/api/v1/devices/${paired.deviceID}/assets`)
            .set("Authorization", `Bearer ${adminKey}`)
            .expect(503);
        assert.equal(response.body.error.code, "DEVICE_OFFLINE");
    });

    it("rejects bridge reads that were not granted during pairing", async () => {
        const session = database.createPairingSession("https://bridge.test");
        const paired = database.pairDevice({
            appVersion: "0.1.0",
            capabilities: [],
            displayName: "Restricted iPhone",
            protocolVersion: 1,
            token: session.token,
        });
        const response = await request(app())
            .get(`/api/v1/devices/${paired.deviceID}/assets`)
            .set("Authorization", `Bearer ${adminKey}`)
            .expect(403);
        assert.equal(response.body.error.code, "CAPABILITY_NOT_GRANTED");
    });

    it("lets an authenticated device revoke its own credential", async () => {
        const session = database.createPairingSession("https://bridge.test");
        const paired = database.pairDevice({
            appVersion: "0.1.0",
            capabilities: [],
            displayName: "Retired iPhone",
            protocolVersion: 1,
            token: session.token,
        });
        await request(app())
            .post("/device/v1/unpair")
            .set("Authorization", `Bearer ${paired.deviceSecret}`)
            .send({ device_id: paired.deviceID })
            .expect(204);
        assert.equal(database.authenticateDevice(paired.deviceID, paired.deviceSecret), false);
    });

    it("creates a scoped API key and revokes it", async () => {
        const created = await request(app())
            .post("/api/v1/api-keys")
            .set("Authorization", `Bearer ${adminKey}`)
            .send({ name: "read-only", scopes: ["library.read"] })
            .expect(201);
        assert.match(created.body.api_key, /^pbk_/);
        await request(app()).get("/api/v1/devices").set("Authorization", `Bearer ${created.body.api_key}`).expect(200);
        await request(app())
            .delete(`/api/v1/api-keys/${created.body.api_key_id}`)
            .set("Authorization", `Bearer ${adminKey}`)
            .expect(204);
        await request(app()).get("/api/v1/devices").set("Authorization", `Bearer ${created.body.api_key}`).expect(401);
    });
});
