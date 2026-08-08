//
//  WritePlan.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation

struct WritePlan: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let contentHash: String
    let serverURL: String?
    let createdAt: Date
    let summary: String
    let targetAlbumName: String
    let createAlbumIfMissing: Bool
    let assetIDs: [String]

    init(
        id: String,
        contentHash: String,
        serverURL: String?,
        createdAt: Date = Date(),
        summary: String,
        targetAlbumName: String,
        createAlbumIfMissing: Bool,
        assetIDs: [String]
    ) {
        let normalizedIDs = Array(Set(assetIDs)).sorted()
        self.id = id
        self.contentHash = contentHash
        self.serverURL = serverURL
        self.createdAt = createdAt
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetAlbumName = targetAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createAlbumIfMissing = createAlbumIfMissing
        self.assetIDs = normalizedIDs
    }
}
