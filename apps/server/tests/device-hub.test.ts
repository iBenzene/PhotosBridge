import assert from "node:assert/strict";
import http from "node:http";
import { afterEach, beforeEach, describe, it } from "node:test";
import { WebSocket } from "ws";
import { PhotosBridgeDatabase } from "../src/database.js";
import { DeviceHub, type ProtocolEnvelope } from "../src/device-hub.js";
import { PlanService } from "../src/plans.js";

let database: PhotosBridgeDatabase;
let hub: DeviceHub;
let server: http.Server;

beforeEach(() => {
    database = new PhotosBridgeDatabase(":memory:");
    hub = new DeviceHub(database);
    server = http.createServer((_request, response) => response.end());
    hub.attach(server);
});

afterEach(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    database.close();
});

describe("DeviceHub durable plan delivery", () => {
    it("delivers an immutable plan after reconnect and persists its storage receipt", async () => {
        const pairing = database.createPairingSession();
        const credentials = database.pairDevice({
            appVersion: "0.1.0",
            capabilities: ["albums.create", "albums.membership.write"],
            displayName: "Queued iPhone",
            protocolVersion: 1,
            token: pairing.token,
        });
        const plan = new PlanService(database).create({
            asset_ids: ["asset-a"],
            device_id: credentials.deviceID,
            idempotency_key: "delivery-test",
            summary: "test",
            target_album: { create_if_missing: true, name: "Test" },
        });
        const deliveryID = hub.enqueuePlanDelivery(
            plan.plan_id,
            new Date(Date.now() + 60_000).toISOString()
        ).delivery_id;
        const queued = database.connection
            .prepare("SELECT status FROM plan_deliveries WHERE id = ?")
            .get(deliveryID) as { status: string };
        assert.equal(queued.status, "queued");

        await new Promise<void>((resolve, reject) =>
            server.listen(0, "127.0.0.1", () => resolve()).once("error", reject)
        );
        const address = server.address();
        assert.ok(address && typeof address === "object");
        const socket = new WebSocket(
            `ws://127.0.0.1:${address.port}/device/v1/connect?device_id=${credentials.deviceID}`,
            { headers: { Authorization: `Bearer ${credentials.deviceSecret}` } }
        );

        await new Promise<void>((resolve, reject) => {
            socket.on("error", reject);
            socket.on("message", async raw => {
                const envelope = JSON.parse(raw.toString()) as ProtocolEnvelope;
                if (envelope.type !== "plans.delivery.request") return;
                assert.equal(envelope.message_id, deliveryID);
                assert.equal((envelope.payload as { plan_id: string }).plan_id, plan.plan_id);
                assert.equal((envelope.payload as { operation: string }).operation, "album_members.add");
                assert.deepEqual((envelope.payload as { asset_ids: string[] }).asset_ids, ["asset-a"]);
                socket.send(
                    JSON.stringify({
                        correlation_id: envelope.message_id,
                        device_id: credentials.deviceID,
                        message_id: "msg_invalid_receipt",
                        payload: { plan_id: "plan_wrong", stored: true },
                        protocol_version: 1,
                        sent_at: new Date().toISOString(),
                        type: "plans.delivery.response",
                    })
                );
                await new Promise(wait => setTimeout(wait, 20));
                const stillSent = database.connection
                    .prepare("SELECT status FROM plan_deliveries WHERE id = ?")
                    .get(deliveryID) as { status: string };
                assert.equal(stillSent.status, "sent");
                socket.send(
                    JSON.stringify({
                        correlation_id: envelope.message_id,
                        device_id: credentials.deviceID,
                        message_id: "msg_receipt",
                        payload: { plan_id: plan.plan_id, stored: true },
                        protocol_version: 1,
                        sent_at: new Date().toISOString(),
                        type: "plans.delivery.response",
                    })
                );
                setTimeout(resolve, 20);
            });
        });

        const stored = database.connection
            .prepare("SELECT status FROM plan_deliveries WHERE id = ?")
            .get(deliveryID) as { status: string };
        assert.equal(stored.status, "stored");
        socket.close();
    });
});
