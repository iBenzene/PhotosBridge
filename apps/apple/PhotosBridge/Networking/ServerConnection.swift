//
//  ServerConnection.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ServerConnection {
    private static let logger = Logger(subsystem: "com.ibenzene.PhotosBridge", category: "ServerConnection")

    private(set) var status: ConnectionStatus = .unpaired {
        didSet {
            if status != oldValue {
                Self.logger.info("Connection status: \(oldValue.title, privacy: .public) -> \(self.status.title, privacy: .public)")
#if DEBUG
                print("[ServerConnection] status: \(oldValue.title) -> \(self.status.title)")
#endif
            }
        }
    }
    private(set) var server: PairedServer?
    private(set) var lastConnectedAt: Date?
    var onEnvelope: ((ProtocolEnvelope) async -> Void)?
    var onConnected: (() async -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeSecret: String?
    private var eventAcknowledgements: [String: CheckedContinuation<Bool, Never>] = [:]

    func pair(baseURL: URL, token: String, displayName: String, capabilities: [String]) async throws -> (PairedServer, String) {
        let endpoint = baseURL.appending(path: "/device/v1/pair")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pairing_token": token,
            "display_name": displayName,
            "app_version": "0.1.0",
            "protocol_version": 1,
            "capabilities": capabilities,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            throw ServerConnectionFailure.pairingRejected
        }
        let payload = try JSONDecoder().decode(PairingResponse.self, from: data)
        let paired = PairedServer(
            baseURL: baseURL, deviceID: payload.deviceID, displayName: displayName,
            capabilities: capabilities
        )
        return (paired, payload.deviceSecret)
    }

    func revokePairing() async {
        guard let server, let activeSecret else {
            disconnect(markUnpaired: true)
            return
        }
        var request = URLRequest(url: server.baseURL.appending(path: "/device/v1/unpair"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(activeSecret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": server.deviceID])

        // Local unpairing must not depend on a reachable server. In particular, a
        // connection attempt can otherwise leave this request waiting while the UI
        // continues to show the device as paired.
        disconnect(markUnpaired: true)
        _ = try? await URLSession.shared.data(for: request)
    }

    func connect(server: PairedServer, secret: String) {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        self.server = server
        activeSecret = secret
        openSocket(server: server, secret: secret)
    }

    func resume() {
        guard status == .disconnected, let server, let activeSecret else { return }
        openSocket(server: server, secret: activeSecret)
    }

    func pause() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if server != nil { status = .disconnected }
    }

    private func openSocket(server: PairedServer, secret: String) {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .connecting
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else {
            status = .disconnected
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/device/v1/connect"
        components.queryItems = [URLQueryItem(name: "device_id", value: server.deviceID)]
        guard let url = components.url else { status = .disconnected; return }
        Self.logger.info("Opening WebSocket: \(url.absoluteString, privacy: .public)")
#if DEBUG
        print("[ServerConnection] opening: \(url.absoluteString)")
#endif
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveTask = Task { await receiveLoop(task) }
        heartbeatTask = Task { await heartbeatLoop(task) }
    }

    func sendResponse(to request: ProtocolEnvelope, type: String, payload: JSONValue) async {
        guard let socket, let server else { return }
        let response = ProtocolEnvelope(
            protocolVersion: 1,
            messageID: "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            correlationID: request.messageID,
            deviceID: server.deviceID,
            type: type,
            sentAt: Date(),
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) {
            try? await socket.send(.string(text))
        }
    }

    func sendEvent(type: String, payload: JSONValue) async -> Bool {
        guard let socket, let server else { return false }
        let messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let envelope = ProtocolEnvelope(
            protocolVersion: 1,
            messageID: messageID,
            correlationID: nil,
            deviceID: server.deviceID,
            type: type,
            sentAt: Date(),
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope), let text = String(data: data, encoding: .utf8) else { return false }
        return await withCheckedContinuation { continuation in
            eventAcknowledgements[messageID] = continuation
            Task { [weak self] in
                do { try await socket.send(.string(text)) }
                catch { self?.finishAcknowledgement(messageID, result: false) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finishAcknowledgement(messageID, result: false)
            }
        }
    }

    func disconnect(markUnpaired: Bool) {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        reconnectTask?.cancel()
        if markUnpaired { server = nil; activeSecret = nil }
        status = markUnpaired ? .unpaired : .disconnected
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        let decoder = ProtocolEnvelope.makeDecoder()
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data = switch message {
                case .string(let text): Data(text.utf8)
                case .data(let data): data
                @unknown default: Data()
                }
                let envelope = try decoder.decode(ProtocolEnvelope.self, from: data)
                guard socket === task else { return }
                guard envelope.protocolVersion == 1 else { continue }
                if envelope.type == "event.ack", let correlationID = envelope.correlationID {
                    finishAcknowledgement(correlationID, result: true)
                } else if envelope.type == "session.ready" {
                    Self.logger.info("WebSocket session is ready")
#if DEBUG
                    print("[ServerConnection] session.ready")
#endif
                    status = .connected
                    lastConnectedAt = Date()
                    Task { await onConnected?() }
                } else {
                    await onEnvelope?(envelope)
                }
            }
        } catch {
            Self.logger.error("WebSocket receive failed: \(String(reflecting: error), privacy: .public); current task: \(self.socket === task)")
#if DEBUG
            print("[ServerConnection] receive failed: \(String(reflecting: error)); current task: \(self.socket === task); cancelled: \(Task.isCancelled)")
#endif
            if !Task.isCancelled, socket === task {
                socket = nil
                status = .disconnected
                scheduleReconnect()
            }
        }
    }

    private func heartbeatLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, socket === task else { return }
            let pingSucceeded = await withCheckedContinuation { continuation in
                task.sendPing { error in continuation.resume(returning: error == nil) }
            }
            if !pingSucceeded, socket === task {
                socket = nil
                status = .disconnected
                scheduleReconnect()
                return
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil || reconnectTask?.isCancelled == true,
              let server, let activeSecret else { return }
        reconnectTask = Task { [weak self] in
            for delay in [1, 2, 4, 8, 16, 30] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.openSocket(server: server, secret: activeSecret)
                try? await Task.sleep(for: .seconds(2))
                if self.status == .connected { self.reconnectTask = nil; return }
            }
            self?.reconnectTask = nil
        }
    }

    private func finishAcknowledgement(_ messageID: String, result: Bool) {
        eventAcknowledgements.removeValue(forKey: messageID)?.resume(returning: result)
    }
}

private struct PairingResponse: Decodable {
    let deviceID: String
    let deviceSecret: String
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceSecret = "device_secret"
    }
}

enum ServerConnectionFailure: Error, LocalizedError {
    case pairingRejected
    var errorDescription: String? {
        String(localized: "服务器拒绝配对。请检查地址、一次性配对码及其有效期。")
    }
}
