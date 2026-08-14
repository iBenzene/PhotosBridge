//
//  PhotoLibraryClient.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import CoreGraphics
import UIKit

enum ThumbnailContentMode: String, Sendable {
    case fit
    case fill
}

@MainActor
protocol PhotoLibraryClient: AnyObject {
    func authorizationLevel() -> PhotoAccessLevel
    func requestAuthorization() async -> PhotoAccessLevel
    func presentLimitedLibraryPicker()
    func assetPage(snapshotID: String?, cursor: String?, limit: Int) async throws -> AssetPage
    func asset(id: String) async throws -> AssetDescriptor
    func thumbnail(
        for assetID: String,
        targetSize: CGSize,
        contentMode: ThumbnailContentMode,
        allowsNetwork: Bool
    ) async throws -> UIImage
    func albums() async throws -> [AlbumDescriptor]
    func assetIDs(inAlbum albumID: String) async throws -> [String]
    func add(assetIDs: [String], toAlbumNamed albumName: String, createIfMissing: Bool) async throws -> OperationResult
    func restore(assetIDs: [String], toAlbumID albumID: String) async throws -> RestoreResult
    func remove(assetIDs: [String], fromAlbumID albumID: String) async throws -> UndoResult
    func move(assetIDs: [String], fromAlbumID: String, toAlbumID: String) async throws -> MoveResult
}
