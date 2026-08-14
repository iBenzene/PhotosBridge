/**
 * @file device-hub.ts
 * @description WebSocket connection hub for device pairing and real-time message routing.
 * @author iBenzene
 */
import type { IncomingMessage, Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import type { PhotosBridgeDatabase } from "./database.js";
import { presentStoredPlan } from "./plans.js";
import { id } from "./database.js";

export type ProtocolEnvelope = {
    protocol_version: 1;
    message_id: string;
    correlation_id: string | null;
    device_id: string;
    type: string;
    sent_at: string;
    payload: unknown;
};

type PendingRequest = {
    resolve: (payload: unknown) => void;
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
};

export type PlanDelivery = {
    delivery_id: string;
    plan_id: string;
    status: string;
    created_at: string;
    delivery_expires_at: string;
};

export class DeviceHub {
    private readonly sockets = new Map<string, WebSocket>();
    private readonly pending = new Map<string, PendingRequest>();
    private readonly websocketServer = new WebSocketServer({ noServer: true });

    constructor(private readonly database: PhotosBridgeDatabase) {}

    attach(server: Server): void {
        server.on("upgrade", (request, socket, head) => {
            const url = new URL(request.url ?? "/", "http://localhost");
            if (url.pathname !== "/device/v1/connect") return socket.destroy();
            const deviceID = url.searchParams.get("device_id") ?? "";
            const secret = bearer(request);
            if (!deviceID || !secret || !this.database.authenticateDevice(deviceID, secret)) return socket.destroy();
            this.websocketServer.handleUpgrade(request, socket, head, websocket => {
                this.accept(deviceID, websocket);
            });
        });
    }

    isOnline(deviceID: string): boolean {
        return this.sockets.get(deviceID)?.readyState === WebSocket.OPEN;
    }

    disconnect(deviceID: string): void {
        this.sockets.get(deviceID)?.close(1008, "device revoked");
        this.sockets.delete(deviceID);
    }

    async request(deviceID: string, type: string, payload: unknown, timeoutMilliseconds = 15_000): Promise<unknown> {
        const socket = this.sockets.get(deviceID);
        if (!socket || socket.readyState !== WebSocket.OPEN) throw new DeviceOfflineError();
        const messageID = id("msg");
        const envelope: ProtocolEnvelope = {
            correlation_id: null,
            device_id: deviceID,
            message_id: messageID,
            payload,
            protocol_version: 1,
            sent_at: new Date().toISOString(),
            type,
        };
        const result = new Promise<unknown>((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(messageID);
                reject(new DeviceTimeoutError());
            }, timeoutMilliseconds);
            this.pending.set(messageID, { reject, resolve, timer });
        });
        socket.send(JSON.stringify(envelope));
        return result;
    }

    enqueuePlanDelivery(planID: string, deliveryExpiresAt: string): PlanDelivery {
        const plan = this.database.connection.prepare("SELECT device_id FROM plans WHERE id = ?").get(planID) as
            { device_id: string } | undefined;
        if (!plan) throw new Error("PLAN_NOT_FOUND");
        const existing = this.database.connection
            .prepare(
                `
      SELECT id FROM plan_deliveries
      WHERE plan_id = ? AND status IN ('queued', 'sent', 'stored')
      ORDER BY created_at DESC LIMIT 1
    `
            )
            .get(planID) as { id: string } | undefined;
        if (existing) return this.getLatestPlanDelivery(planID)!;
        const deliveryID = id("delivery");
        const timestamp = new Date().toISOString();
        this.database.connection
            .prepare(
                `INSERT INTO plan_deliveries
      (id, plan_id, status, created_at, delivery_expires_at)
      VALUES (?, ?, 'queued', ?, ?)`
            )
            .run(deliveryID, planID, timestamp, deliveryExpiresAt);
        this.deliverQueued(plan.device_id);
        return this.getLatestPlanDelivery(planID)!;
    }

    getLatestPlanDelivery(planID: string): PlanDelivery | undefined {
        return this.database.connection
            .prepare(
                `SELECT id AS delivery_id, plan_id, status, created_at, delivery_expires_at
                 FROM plan_deliveries WHERE plan_id = ? ORDER BY created_at DESC LIMIT 1`
            )
            .get(planID) as PlanDelivery | undefined;
    }

    private accept(deviceID: string, socket: WebSocket): void {
        this.sockets.get(deviceID)?.close(1000, "replaced by a newer connection");
        this.sockets.set(deviceID, socket);
        this.database.touchDevice(deviceID);
        socket.on("pong", () => this.database.touchDevice(deviceID));
        socket.on("message", data => this.receive(deviceID, data.toString()));
        socket.on("close", () => {
            if (this.sockets.get(deviceID) === socket) this.sockets.delete(deviceID);
        });
        socket.send(
            JSON.stringify({
                correlation_id: null,
                device_id: deviceID,
                message_id: id("msg"),
                payload: { heartbeat_seconds: 25 },
                protocol_version: 1,
                sent_at: new Date().toISOString(),
                type: "session.ready",
            } satisfies ProtocolEnvelope)
        );
        this.deliverQueued(deviceID);
    }

    private receive(deviceID: string, raw: string): void {
        let envelope: ProtocolEnvelope;
        try {
            envelope = JSON.parse(raw) as ProtocolEnvelope;
        } catch {
            return;
        }
        if (envelope.protocol_version !== 1 || envelope.device_id !== deviceID) return;
        this.database.touchDevice(deviceID);
        if (!envelope.correlation_id) return;
        const delivery = this.database.connection
            .prepare(
                `SELECT pd.id, pd.plan_id FROM plan_deliveries pd
                 JOIN plans p ON p.id = pd.plan_id
                 WHERE pd.id = ? AND p.device_id = ?`
            )
            .get(envelope.correlation_id, deviceID) as { id: string; plan_id: string } | undefined;
        if (delivery) {
            const payload = envelope.payload as { plan_id?: unknown; stored?: unknown } | null;
            const stored =
                envelope.type === "plans.delivery.response" &&
                payload?.stored === true &&
                payload.plan_id === delivery.plan_id;
            if (stored) {
                this.database.connection
                    .prepare("UPDATE plan_deliveries SET status = 'stored' WHERE id = ?")
                    .run(delivery.id);
            } else if (envelope.type === "plans.delivery.error") {
                this.database.connection
                    .prepare("UPDATE plan_deliveries SET status = 'failed' WHERE id = ?")
                    .run(delivery.id);
            }
        }
        const pending = this.pending.get(envelope.correlation_id);
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pending.delete(envelope.correlation_id);
        if (envelope.type.endsWith(".error")) pending.reject(new DeviceResponseError(envelope.payload));
        else pending.resolve(envelope.payload);
    }

    private deliverQueued(deviceID: string): void {
        const socket = this.sockets.get(deviceID);
        if (!socket || socket.readyState !== WebSocket.OPEN) return;
        const deliveries = this.database.connection
            .prepare(
                `
      SELECT pd.id, p.id AS plan_id, p.summary,
             p.operation, p.source_album_json, p.target_album_json,
             p.asset_ids_json, p.content_hash, p.created_at
      FROM plan_deliveries pd JOIN plans p ON p.id = pd.plan_id
      WHERE p.device_id = ? AND pd.status IN ('queued', 'sent') AND pd.delivery_expires_at > ?
      ORDER BY pd.created_at ASC
    `
            )
            .all(deviceID, new Date().toISOString()) as Array<Record<string, unknown>>;
        for (const delivery of deliveries) {
            const plan = presentStoredPlan({ ...delivery, device_id: deviceID, id: delivery.plan_id });
            const envelope: ProtocolEnvelope = {
                correlation_id: null,
                device_id: deviceID,
                message_id: String(delivery.id),
                payload: {
                    ...plan,
                },
                protocol_version: 1,
                sent_at: new Date().toISOString(),
                type: "plans.delivery.request",
            };
            socket.send(JSON.stringify(envelope));
            this.database.connection
                .prepare("UPDATE plan_deliveries SET status = 'sent' WHERE id = ?")
                .run(delivery.id);
        }
        this.database.connection
            .prepare(
                `UPDATE plan_deliveries SET status = 'expired'
                 WHERE id IN (
                   SELECT pd.id FROM plan_deliveries pd JOIN plans p ON p.id = pd.plan_id
                   WHERE p.device_id = ? AND pd.status IN ('queued', 'sent') AND pd.delivery_expires_at <= ?
                 )`
            )
            .run(deviceID, new Date().toISOString());
    }
}

export class DeviceOfflineError extends Error {
    readonly code = "DEVICE_OFFLINE";
}
export class DeviceTimeoutError extends Error {
    readonly code = "DEVICE_TIMEOUT";
}
export class DeviceResponseError extends Error {
    readonly code = "DEVICE_RESPONSE_ERROR";
    constructor(readonly payload: unknown) {
        super("Device returned an error");
    }
}

const bearer = (request: IncomingMessage): string | null => {
    const value = request.headers.authorization;
    return value?.startsWith("Bearer ") ? value.slice(7) : null;
};
