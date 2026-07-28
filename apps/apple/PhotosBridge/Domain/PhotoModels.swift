//
//  PhotoModels.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation

enum PhotoAccessLevel: String, Codable, Sendable {
    case notDetermined
    case limited
    case full
    case denied
    case restricted

    var canRead: Bool { self == .full || self == .limited }

    var title: String {
        switch self {
        case .notDetermined: String(localized: "尚未授权")
        case .limited: String(localized: "有限访问")
        case .full: String(localized: "全部照片")
        case .denied: String(localized: "已拒绝")
        case .restricted: String(localized: "受系统限制")
        }
    }
}

enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

struct AssetDescriptor: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let kind: MediaKind
    let subtype: String?
    let createdAt: Date?
    let modifiedAt: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let isFavorite: Bool
    let isHidden: Bool
    let hasLocation: Bool
}

struct AssetPage: Equatable, Codable, Sendable {
    let snapshotID: String
    let items: [AssetDescriptor]
    let nextCursor: String?
}

struct AlbumDescriptor: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
    let isWritable: Bool
}

struct OperationCounts: Equatable, Codable, Sendable {
    let requested: Int
    let added: Int
    let skippedExisting: Int
    let missing: Int
    let failed: Int
}

struct OperationResult: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let albumID: String?
    let albumName: String
    let counts: OperationCounts
    let addedAssetIDs: [String]
    let failedAssetIDs: [String]
}

struct UndoResult: Equatable, Codable, Sendable {
    let requested: Int
    let removed: Int
    let missing: Int
    let failed: Int
    let removedAssetIDs: [String]
}

struct UndoPlan: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let remoteID: String?
    let batchID: String
    let albumID: String
    let albumName: String
    let assetIDs: [String]
}

struct HistoryRecord: Identifiable, Equatable, Codable, Sendable {
    var id: UUID { result.id }
    let result: OperationResult
    let batchID: String
    var undoResult: UndoResult?

    var isUndoable: Bool { !result.addedAssetIDs.isEmpty && undoResult == nil }
}

enum PhotoLibraryFailure: Error, Equatable, LocalizedError {
    case permissionInsufficient
    case snapshotInvalidated
    case albumAmbiguous(String)
    case albumNotWritable
    case albumCreationFailed
    case photoKit(String)

    var errorDescription: String? {
        switch self {
        case .permissionInsufficient: String(localized: "照片权限不足。")
        case .snapshotInvalidated: String(localized: "照片库已经变化，请重新加载。")
        case .albumAmbiguous(let name):
            String(format: String(localized: "存在多个名为“%@”的相册，请明确选择目标相册。"), name)
        case .albumNotWritable: String(localized: "目标相册不可写。")
        case .albumCreationFailed: String(localized: "无法创建目标相册。")
        case .photoKit(let message): message
        }
    }
}
