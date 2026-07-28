//
//  ProtocolEnvelope.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation
import CryptoKit

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): String(Int(value))
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    func canonicalSHA256() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: foundationObject, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var foundationObject: Any {
        switch self {
        case .object(let value): value.mapValues(\.foundationObject)
        case .array(let value): value.map(\.foundationObject)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

struct ProtocolEnvelope: Codable, Sendable {
    let protocolVersion: Int
    let messageID: String
    let correlationID: String?
    let deviceID: String
    let type: String
    let sentAt: Date
    let payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case messageID = "message_id"
        case correlationID = "correlation_id"
        case deviceID = "device_id"
        case type
        case sentAt = "sent_at"
        case payload
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parseDate(value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 date with optional fractional seconds."
            )
        }
        return decoder
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct PairedServer: Codable, Equatable, Sendable {
    let baseURL: URL
    let deviceID: String
    let displayName: String
    let capabilities: [String]?

    func grants(_ capability: String) -> Bool { capabilities?.contains(capability) == true }
}

enum ConnectionStatus: Equatable {
    case unpaired
    case connecting
    case connected
    case disconnected
    case authenticationFailed

    var title: String {
        switch self {
        case .unpaired: String(localized: "尚未配对")
        case .connecting: String(localized: "正在连接")
        case .connected: String(localized: "已连接")
        case .disconnected: String(localized: "已断开")
        case .authenticationFailed: String(localized: "认证失败")
        }
    }
}
