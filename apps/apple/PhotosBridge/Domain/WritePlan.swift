//
//  WritePlan.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation

enum WritePlanOperation: String, Codable, Sendable {
    case albumMembersAdd = "album_members.add"
    case albumMembersRemove = "album_members.remove"
    case albumMembersMove = "album_members.move"
}

struct WritePlan: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let contentHash: String
    let serverURL: String?
    let createdAt: Date
    let operation: WritePlanOperation
    let summary: String
    let sourceAlbumID: String?
    let sourceAlbumName: String?
    let targetAlbumID: String?
    let targetAlbumName: String
    let createAlbumIfMissing: Bool
    let assetIDs: [String]

    init(
        id: String,
        contentHash: String,
        serverURL: String?,
        createdAt: Date = Date(),
        operation: WritePlanOperation = .albumMembersAdd,
        summary: String,
        sourceAlbumID: String? = nil,
        sourceAlbumName: String? = nil,
        targetAlbumID: String? = nil,
        targetAlbumName: String = "",
        createAlbumIfMissing: Bool = false,
        assetIDs: [String]
    ) {
        let normalizedIDs = Array(Set(assetIDs)).sorted()
        self.id = id
        self.contentHash = contentHash
        self.serverURL = serverURL
        self.createdAt = createdAt
        self.operation = operation
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceAlbumID = sourceAlbumID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceAlbumName = sourceAlbumName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetAlbumID = targetAlbumID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetAlbumName = targetAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createAlbumIfMissing = createAlbumIfMissing
        self.assetIDs = normalizedIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, contentHash, serverURL, createdAt, operation, summary
        case sourceAlbumID, sourceAlbumName, targetAlbumID
        case targetAlbumName, createAlbumIfMissing, assetIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            contentHash: try container.decode(String.self, forKey: .contentHash),
            serverURL: try container.decodeIfPresent(String.self, forKey: .serverURL),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            operation: try container.decodeIfPresent(WritePlanOperation.self, forKey: .operation) ?? .albumMembersAdd,
            summary: try container.decode(String.self, forKey: .summary),
            sourceAlbumID: try container.decodeIfPresent(String.self, forKey: .sourceAlbumID),
            sourceAlbumName: try container.decodeIfPresent(String.self, forKey: .sourceAlbumName),
            targetAlbumID: try container.decodeIfPresent(String.self, forKey: .targetAlbumID),
            targetAlbumName: try container.decodeIfPresent(String.self, forKey: .targetAlbumName) ?? "",
            createAlbumIfMissing: try container.decodeIfPresent(Bool.self, forKey: .createAlbumIfMissing) ?? false,
            assetIDs: try container.decode([String].self, forKey: .assetIDs)
        )
    }
}
