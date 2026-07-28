/**
 * @file device-hub.ts
 * @description WebSocket connection hub for device pairing and real-time message routing.
 * @author iBenzene
 */
import type { IncomingMessage, Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import type { PhotosBridgeDatabase } from "./database.js";
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

export class DeviceHub {
    private readonly sockets = new Map<string, WebSocket>();
    private readonly pending = new Map<string, PendingRequest>();
    private readonly websocketServer = new WebSocketServer({ noServer: true });
    private eventHandler: ((type: string, payload: unknown, deviceID: string) => void) | undefined;
    private responseHandler:
        ((requestType: string, responseType: string, payload: unknown, deviceID: string) => void) | undefined;

    constructor(private readonly database: PhotosBridgeDatabase) {}

    onEvent(handler: (type: string, payload: unknown, deviceID: string) => void): void {
        this.eventHandler = handler;
    }
    onResponse(handler: (requestType: string, responseType: string, payload: unknown, deviceID: string) => void): void {
        this.responseHandler = handler;
    }

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

    enqueue(deviceID: string, type: string, payload: unknown, expiresAt: string): string {
        const payloadJSON = JSON.stringify(payload);
        const existing = this.database.connection
            .prepare(
                `
      SELECT id FROM commands
      WHERE device_id = ? AND type = ? AND payload_json = ? AND status IN ('queued', 'sent')
      ORDER BY created_at DESC LIMIT 1
    `
            )
            .get(deviceID, type, payloadJSON) as { id: string } | undefined;
        if (existing) return existing.id;
        const messageID = id("msg");
        const timestamp = new Date().toISOString();
        this.database.connection
            .prepare(
                `INSERT INTO commands
      (id, device_id, type, payload_json, status, created_at, updated_at, expires_at)
      VALUES (?, ?, ?, ?, 'queued', ?, ?, ?)`
            )
            .run(messageID, deviceID, type, payloadJSON, timestamp, timestamp, expiresAt);
        this.deliverQueued(deviceID);
        return messageID;
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
        if (!envelope.correlation_id) {
            this.eventHandler?.(envelope.type, envelope.payload, deviceID);
            const socket = this.sockets.get(deviceID);
            if (socket?.readyState === WebSocket.OPEN) {
                socket.send(
                    JSON.stringify({
                        correlation_id: envelope.message_id,
                        device_id: deviceID,
                        message_id: id("msg"),
                        payload: { accepted: true },
                        protocol_version: 1,
                        sent_at: new Date().toISOString(),
                        type: "event.ack",
                    } satisfies ProtocolEnvelope)
                );
            }
            return;
        }
        const command = this.database.connection
            .prepare("SELECT type FROM commands WHERE id = ? AND device_id = ?")
            .get(envelope.correlation_id, deviceID) as { type: string } | undefined;
        if (command) {
            const status = envelope.type.endsWith(".error") ? "failed" : "completed";
            this.database.connection
                .prepare("UPDATE commands SET status = ?, result_json = ?, updated_at = ? WHERE id = ?")
                .run(status, JSON.stringify(envelope.payload), new Date().toISOString(), envelope.correlation_id);
            this.responseHandler?.(command.type, envelope.type, envelope.payload, deviceID);
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
        const commands = this.database.connection
            .prepare(
                `
      SELECT id, type, payload_json FROM commands
      WHERE device_id = ? AND status IN ('queued', 'sent') AND expires_at > ?
      ORDER BY created_at ASC
    `
            )
            .all(deviceID, new Date().toISOString()) as Array<{ id: string; type: string; payload_json: string }>;
        for (const command of commands) {
            const envelope: ProtocolEnvelope = {
                correlation_id: null,
                device_id: deviceID,
                message_id: command.id,
                payload: JSON.parse(command.payload_json),
                protocol_version: 1,
                sent_at: new Date().toISOString(),
                type: command.type,
            };
            socket.send(JSON.stringify(envelope));
            this.database.connection
                .prepare("UPDATE commands SET status = 'sent', updated_at = ? WHERE id = ?")
                .run(new Date().toISOString(), command.id);
        }
        this.database.connection
            .prepare(
                "UPDATE commands SET status = 'expired', updated_at = ? WHERE device_id = ? AND status IN ('queued', 'sent') AND expires_at <= ?"
            )
            .run(new Date().toISOString(), deviceID, new Date().toISOString());
    }
}

export class DeviceOfflineError extends Error {
    readonly code = "DEVICE_OFFLINE";
}
export class DeviceTimeoutError extends Error {
    readonly code = "OPERATION_STATE_UNKNOWN";
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
