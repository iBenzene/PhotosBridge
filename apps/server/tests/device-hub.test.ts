import assert from "node:assert/strict";
import http from "node:http";
import { afterEach, beforeEach, describe, it } from "node:test";
import { WebSocket } from "ws";
import { PhotosBridgeDatabase } from "../src/database.js";
import { DeviceHub, type ProtocolEnvelope } from "../src/device-hub.js";

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

describe("DeviceHub durable commands", () => {
    it("delivers an offline command after reconnect and persists its receipt", async () => {
        const pairing = database.createPairingSession("https://bridge.test");
        const credentials = database.pairDevice({
            appVersion: "0.1.0",
            capabilities: ["albums.membership.write"],
            displayName: "Queued iPhone",
            protocolVersion: 1,
            token: pairing.token,
        });
        const commandID = hub.enqueue(
            credentials.deviceID,
            "plans.approval.request",
            { plan_id: "plan_test" },
            new Date(Date.now() + 60_000).toISOString()
        );
        const queued = database.connection.prepare("SELECT status FROM commands WHERE id = ?").get(commandID) as {
            status: string;
        };
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
            socket.on("message", raw => {
                const envelope = JSON.parse(raw.toString()) as ProtocolEnvelope;
                if (envelope.type !== "plans.approval.request") return;
                assert.equal(envelope.message_id, commandID);
                socket.send(
                    JSON.stringify({
                        correlation_id: envelope.message_id,
                        device_id: credentials.deviceID,
                        message_id: "msg_receipt",
                        payload: { accepted: true, plan_id: "plan_test" },
                        protocol_version: 1,
                        sent_at: new Date().toISOString(),
                        type: "plans.approval.response",
                    })
                );
                setTimeout(resolve, 20);
            });
        });

        const completed = database.connection.prepare("SELECT status FROM commands WHERE id = ?").get(commandID) as {
            status: string;
        };
        assert.equal(completed.status, "completed");
        socket.close();
    });
});
