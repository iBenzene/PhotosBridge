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

struct OperationResult: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let albumID: String
    let albumName: String
    let addedAssetIDs: [String]
    let alreadyPresentAssetIDs: [String]
    let missingAssetIDs: [String]
    let failedAssetIDs: [String]

    var requested: Int { added + alreadyPresent + missing + failed }
    var added: Int { addedAssetIDs.count }
    var alreadyPresent: Int { alreadyPresentAssetIDs.count }
    var missing: Int { missingAssetIDs.count }
    var failed: Int { failedAssetIDs.count }
}

struct UndoResult: Equatable, Codable, Sendable {
    let removedAssetIDs: [String]
    let missingAssetIDs: [String]
    let failedAssetIDs: [String]

    var requested: Int { removed + missing + failed }
    var removed: Int { removedAssetIDs.count }
    var missing: Int { missingAssetIDs.count }
    var failed: Int { failedAssetIDs.count }
}

struct MoveResult: Equatable, Codable, Sendable {
    let movedAssetIDs: [String]
    let alreadyPresentAtTargetAssetIDs: [String]
    let missingFromSourceAssetIDs: [String]

    var requested: Int { movedAssetIDs.count + missingFromSourceAssetIDs.count }
    var moved: Int { movedAssetIDs.count }
    var alreadyPresentAtTarget: Int { alreadyPresentAtTargetAssetIDs.count }
    var missingFromSource: Int { missingFromSourceAssetIDs.count }
}

struct MembershipMutationSelection: Equatable, Sendable {
    let selectedAssetIDs: [String]
    let additionsToTargetAssetIDs: [String]
    let alreadyPresentAtTargetAssetIDs: [String]
    let missingFromSourceAssetIDs: [String]

    static func remove(requestedAssetIDs: [String], sourceMemberIDs: Set<String>) -> Self {
        let requested = Array(Set(requestedAssetIDs)).sorted()
        return Self(
            selectedAssetIDs: requested.filter(sourceMemberIDs.contains),
            additionsToTargetAssetIDs: [],
            alreadyPresentAtTargetAssetIDs: [],
            missingFromSourceAssetIDs: requested.filter { !sourceMemberIDs.contains($0) }
        )
    }

    static func move(
        requestedAssetIDs: [String],
        sourceMemberIDs: Set<String>,
        targetMemberIDs: Set<String>
    ) -> Self {
        let removal = remove(requestedAssetIDs: requestedAssetIDs, sourceMemberIDs: sourceMemberIDs)
        return Self(
            selectedAssetIDs: removal.selectedAssetIDs,
            additionsToTargetAssetIDs: removal.selectedAssetIDs.filter { !targetMemberIDs.contains($0) },
            alreadyPresentAtTargetAssetIDs: removal.selectedAssetIDs.filter(targetMemberIDs.contains),
            missingFromSourceAssetIDs: removal.missingFromSourceAssetIDs
        )
    }
}

struct RestoreResult: Equatable, Codable, Sendable {
    let addedAssetIDs: [String]
    let alreadyPresentAssetIDs: [String]
    let missingAssetIDs: [String]
    let failedAssetIDs: [String]

    var restored: Int { addedAssetIDs.count }
    var alreadyPresent: Int { alreadyPresentAssetIDs.count }
    var missing: Int { missingAssetIDs.count }
    var failed: Int { failedAssetIDs.count }
    var recoveredAssetIDs: [String] {
        Array(Set(addedAssetIDs).union(alreadyPresentAssetIDs)).sorted()
    }

    func merging(_ attempt: RestoreResult) -> RestoreResult {
        let added = Set(addedAssetIDs).union(attempt.addedAssetIDs)
        let alreadyPresent = Set(alreadyPresentAssetIDs)
            .union(attempt.alreadyPresentAssetIDs)
            .subtracting(added)
        return RestoreResult(
            addedAssetIDs: added.sorted(),
            alreadyPresentAssetIDs: alreadyPresent.sorted(),
            missingAssetIDs: Array(Set(attempt.missingAssetIDs)).sorted(),
            failedAssetIDs: Array(Set(attempt.failedAssetIDs)).sorted()
        )
    }
}

enum PendingHistoryAction: Identifiable, Equatable, Codable, Sendable {
    case undo(UUID)
    case restore(UUID)

    var recordID: UUID {
        switch self {
        case .undo(let id), .restore(let id): id
        }
    }

    var id: String {
        switch self {
        case .undo(let id): "undo-\(id.uuidString)"
        case .restore(let id): "restore-\(id.uuidString)"
        }
    }
}

enum LocalBatchState: String, Equatable, Codable, Sendable {
    case completed
    case partiallyUndone
    case undone
    case partiallyRestored
    case restored
}

struct HistoryRecord: Identifiable, Equatable, Codable, Sendable {
    var id: UUID { result.id }
    let result: OperationResult
    var undoResult: UndoResult?
    var restoreResult: RestoreResult? = nil

    var restorableAssetIDs: [String] {
        guard let undoResult else { return [] }
        let recovered = Set(restoreResult?.recoveredAssetIDs ?? [])
        return undoResult.removedAssetIDs.filter { !recovered.contains($0) }.sorted()
    }

    var localState: LocalBatchState {
        guard let undoResult, !undoResult.removedAssetIDs.isEmpty else { return .completed }
        let recoveredCount = restoreResult?.recoveredAssetIDs.count ?? 0
        if restorableAssetIDs.isEmpty { return .restored }
        if recoveredCount > 0 { return .partiallyRestored }
        return undoResult.removedAssetIDs.count < result.addedAssetIDs.count ? .partiallyUndone : .undone
    }

    var isUndoable: Bool {
        !result.addedAssetIDs.isEmpty && [.completed, .restored].contains(localState)
    }
    var isRestorable: Bool { [.partiallyUndone, .undone, .partiallyRestored].contains(localState) }

}

enum PhotoLibraryFailure: Error, Equatable, LocalizedError {
    case permissionInsufficient
    case snapshotInvalidated
    case albumAmbiguous(String)
    case albumNotFound
    case albumNotWritable
    case albumCreationFailed
    case invalidAlbumMove
    case photoKit(String)

    var errorDescription: String? {
        switch self {
        case .permissionInsufficient: String(localized: "照片权限不足。")
        case .snapshotInvalidated: String(localized: "照片库已经变化，请重新加载。")
        case .albumAmbiguous(let name):
            String(format: String(localized: "存在多个名为“%@”的相册，请明确选择目标相册。"), name)
        case .albumNotFound: String(localized: "目标相册不存在，且计划不允许创建相册。")
        case .albumNotWritable: String(localized: "目标相册不可写。")
        case .albumCreationFailed: String(localized: "无法创建目标相册。")
        case .invalidAlbumMove: String(localized: "移动照片需要两个不同且可写的现有相册。")
        case .photoKit(let message): message
        }
    }
}
