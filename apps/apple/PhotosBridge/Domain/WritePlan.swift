//
//  WritePlan.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import CryptoKit
import Foundation

struct WritePlan: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let summary: String
    let targetAlbumName: String
    let assetIDs: [String]
    let contentHash: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        summary: String,
        targetAlbumName: String,
        assetIDs: [String]
    ) {
        let normalizedIDs = Array(Set(assetIDs)).sorted()
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(7 * 24 * 60 * 60)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetAlbumName = targetAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.assetIDs = normalizedIDs
        self.contentHash = Self.hash(
            summary: self.summary,
            targetAlbumName: self.targetAlbumName,
            assetIDs: normalizedIDs
        )
    }

    var isExpired: Bool { expiresAt <= Date() }

    private static func hash(summary: String, targetAlbumName: String, assetIDs: [String]) -> String {
        // This deliberately small canonical representation is stable for the
        // local alpha. Protocol plans use RFC 8785 canonical JSON.
        let fields = [summary, targetAlbumName] + assetIDs
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct PendingWritePlan: Identifiable, Equatable, Codable, Sendable {
    let plan: WritePlan
    let remoteContext: RemotePlanContext?

    var id: UUID { plan.id }
    var isRemote: Bool { remoteContext != nil }
}
