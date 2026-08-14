//
//  DemoPhotoLibraryClient.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import CoreGraphics
import UIKit

@MainActor
final class DemoPhotoLibraryClient: PhotoLibraryClient {
    private let demoAssets = [
        AssetDescriptor(
            id: "demo-1", kind: .image, subtype: nil, createdAt: Date(), modifiedAt: Date(),
            pixelWidth: 1600, pixelHeight: 1200, duration: 0,
            isFavorite: false, isHidden: false, hasLocation: false
        ),
        AssetDescriptor(
            id: "demo-2", kind: .video, subtype: nil, createdAt: Date(), modifiedAt: Date(),
            pixelWidth: 1920, pixelHeight: 1080, duration: 12,
            isFavorite: false, isHidden: false, hasLocation: false
        )
    ]

    func authorizationLevel() -> PhotoAccessLevel { .full }
    func requestAuthorization() async -> PhotoAccessLevel { .full }
    func presentLimitedLibraryPicker() {}
    func assetPage(snapshotID: String?, cursor: String?, limit: Int) async throws -> AssetPage {
        AssetPage(snapshotID: "demo-snapshot", items: cursor == nil ? demoAssets : [], nextCursor: nil)
    }
    func asset(id: String) async throws -> AssetDescriptor {
        guard let asset = demoAssets.first(where: { $0.id == id }) else {
            throw PhotoLibraryFailure.photoKit("Demo asset missing")
        }
        return asset
    }
    func thumbnail(
        for assetID: String,
        targetSize: CGSize,
        contentMode: ThumbnailContentMode,
        allowsNetwork: Bool
    ) async throws -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        return renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
    }
    func albums() async throws -> [AlbumDescriptor] {
        [AlbumDescriptor(id: "demo-album", title: "Photos Bridge Test", assetCount: 0, isWritable: true)]
    }
    func assetIDs(inAlbum albumID: String) async throws -> [String] { [] }
    func add(assetIDs: [String], toAlbumNamed albumName: String, createIfMissing: Bool) async throws -> OperationResult {
        OperationResult(
            id: UUID(), albumID: "demo-album", albumName: albumName,
            addedAssetIDs: assetIDs,
            alreadyPresentAssetIDs: [], missingAssetIDs: [], failedAssetIDs: []
        )
    }
    func restore(assetIDs: [String], toAlbumID albumID: String) async throws -> RestoreResult {
        RestoreResult(
            addedAssetIDs: assetIDs, alreadyPresentAssetIDs: [],
            missingAssetIDs: [], failedAssetIDs: []
        )
    }
    func remove(assetIDs: [String], fromAlbumID albumID: String) async throws -> UndoResult {
        UndoResult(removedAssetIDs: assetIDs, missingAssetIDs: [], failedAssetIDs: [])
    }
    func move(assetIDs: [String], fromAlbumID: String, toAlbumID: String) async throws -> MoveResult {
        MoveResult(
            movedAssetIDs: assetIDs,
            alreadyPresentAtTargetAssetIDs: [],
            missingFromSourceAssetIDs: []
        )
    }
}
