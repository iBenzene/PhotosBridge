//
//  PhotoKitLibraryClient.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Photos
import PhotosUI
import UIKit

@MainActor
final class PhotoKitLibraryClient: NSObject, PhotoLibraryClient, PHPhotoLibraryChangeObserver {
    private let imageManager = PHCachingImageManager()
    private var snapshot: (id: String, result: PHFetchResult<PHAsset>)?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func authorizationLevel() -> PhotoAccessLevel {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAccessLevel {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }

    func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    func assetPage(snapshotID: String?, cursor: String?, limit: Int) async throws -> AssetPage {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }

        if let snapshotID, snapshot?.id != snapshotID {
            throw PhotoLibraryFailure.snapshotInvalidated
        }

        if snapshot == nil {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            snapshot = (UUID().uuidString, PHAsset.fetchAssets(with: options))
        }

        guard let snapshot else { throw PhotoLibraryFailure.snapshotInvalidated }
        let bounds = try SnapshotPageBounds.calculate(
            totalCount: snapshot.result.count, cursor: cursor, requestedLimit: limit
        )

        var items: [AssetDescriptor] = []
        items.reserveCapacity(bounds.range.count)
        if !bounds.range.isEmpty {
            for index in bounds.range {
                items.append(Self.describe(snapshot.result.object(at: index)))
            }
        }

        return AssetPage(
            snapshotID: snapshot.id,
            items: items,
            nextCursor: bounds.nextCursor
        )
    }

    func thumbnail(
        for assetID: String,
        targetSize: CGSize,
        contentMode: ThumbnailContentMode,
        allowsNetwork: Bool
    ) async throws -> UIImage {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw PhotoLibraryFailure.photoKit(String(localized: "资源不存在或不在当前授权范围内。"))
        }

        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowsNetwork

            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode.photoKitContentMode,
                options: options
            ) { image, info in
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: PhotoLibraryFailure.photoKit(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: PhotoLibraryFailure.photoKit(String(localized: "无法生成缩略图。")))
                }
            }
        }
    }

    func asset(id: String) async throws -> AssetDescriptor {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoLibraryFailure.photoKit(String(localized: "资源不存在或不在当前授权范围内。"))
        }
        return Self.describe(asset)
    }

    func albums() async throws -> [AlbumDescriptor] {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albums: [AlbumDescriptor] = []
        result.enumerateObjects { collection, _, _ in
            albums.append(
                AlbumDescriptor(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? String(localized: "未命名相册"),
                    assetCount: PHAsset.fetchAssets(in: collection, options: nil).count,
                    isWritable: collection.canPerform(.addContent)
                )
            )
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func assetIDs(inAlbum albumID: String) async throws -> [String] {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }
        guard let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        ).firstObject else {
            throw PhotoLibraryFailure.photoKit(String(localized: "相册不存在或不在当前授权范围内。"))
        }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var identifiers: [String] = []
        identifiers.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        return identifiers
    }

    func add(assetIDs: [String], toAlbumNamed albumName: String, createIfMissing: Bool) async throws -> OperationResult {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }
        let uniqueIDs = Array(Set(assetIDs)).sorted()
        let album = try await resolveAlbum(named: albumName, createIfMissing: createIfMissing)
        guard album.canPerform(.addContent) else { throw PhotoLibraryFailure.albumNotWritable }

        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: nil)
        var found: [PHAsset] = []
        fetchedAssets.enumerateObjects { asset, _, _ in found.append(asset) }
        let foundIDs = Set(found.map(\.localIdentifier))
        let missingIDs = uniqueIDs.filter { !foundIDs.contains($0) }

        let existingResult = PHAsset.fetchAssets(in: album, options: nil)
        var existingIDs = Set<String>()
        existingResult.enumerateObjects { asset, _, _ in existingIDs.insert(asset.localIdentifier) }
        let additions = found.filter { !existingIDs.contains($0.localIdentifier) }

        guard !additions.isEmpty else {
            return OperationResult(
                id: UUID(), albumID: album.localIdentifier, albumName: albumName,
                addedAssetIDs: [],
                alreadyPresentAssetIDs: found.filter { existingIDs.contains($0.localIdentifier) }.map(\.localIdentifier).sorted(),
                missingAssetIDs: missingIDs, failedAssetIDs: []
            )
        }

        var addedIDs: [String] = []
        var failedIDs: [String] = []
        for start in stride(from: 0, to: additions.count, by: 100) {
            let batch = Array(additions[start..<min(start + 100, additions.count)])
            do {
                try await add(batch, to: album)
                addedIDs.append(contentsOf: batch.map(\.localIdentifier))
            } catch {
                // PhotoKit reports a transaction-level error. Retry each asset
                // only after the failed transaction, so the result identifies
                // exact failures without duplicating successful membership.
                for asset in batch {
                    do { try await add([asset], to: album); addedIDs.append(asset.localIdentifier) }
                    catch { failedIDs.append(asset.localIdentifier) }
                }
            }
        }
        return OperationResult(
            id: UUID(), albumID: album.localIdentifier, albumName: albumName,
            addedAssetIDs: addedIDs.sorted(),
            alreadyPresentAssetIDs: found.filter { existingIDs.contains($0.localIdentifier) }.map(\.localIdentifier).sorted(),
            missingAssetIDs: missingIDs, failedAssetIDs: failedIDs.sorted()
        )
    }

    func restore(assetIDs: [String], toAlbumID albumID: String) async throws -> RestoreResult {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }
        guard let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        ).firstObject else {
            throw PhotoLibraryFailure.photoKit(String(localized: "相册不存在或不在当前授权范围内。"))
        }
        guard album.canPerform(.addContent) else { throw PhotoLibraryFailure.albumNotWritable }

        let uniqueIDs = Array(Set(assetIDs)).sorted()
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: nil)
        var found: [PHAsset] = []
        fetchedAssets.enumerateObjects { asset, _, _ in found.append(asset) }
        let foundIDs = Set(found.map(\.localIdentifier))
        let missingIDs = uniqueIDs.filter { !foundIDs.contains($0) }

        let members = PHAsset.fetchAssets(in: album, options: nil)
        var memberIDs = Set<String>()
        members.enumerateObjects { asset, _, _ in memberIDs.insert(asset.localIdentifier) }
        let alreadyPresentIDs = uniqueIDs.filter { foundIDs.contains($0) && memberIDs.contains($0) }
        let additions = found.filter { !memberIDs.contains($0.localIdentifier) }

        var addedIDs: [String] = []
        var failedIDs: [String] = []
        for start in stride(from: 0, to: additions.count, by: 100) {
            let batch = Array(additions[start..<min(start + 100, additions.count)])
            do {
                try await add(batch, to: album)
                addedIDs.append(contentsOf: batch.map(\.localIdentifier))
            } catch {
                for asset in batch {
                    do { try await add([asset], to: album); addedIDs.append(asset.localIdentifier) }
                    catch { failedIDs.append(asset.localIdentifier) }
                }
            }
        }
        return RestoreResult(
            addedAssetIDs: addedIDs.sorted(),
            alreadyPresentAssetIDs: alreadyPresentIDs.sorted(),
            missingAssetIDs: missingIDs.sorted(),
            failedAssetIDs: failedIDs.sorted()
        )
    }

    func remove(assetIDs: [String], fromAlbumID albumID: String) async throws -> UndoResult {
        guard authorizationLevel().canRead else { throw PhotoLibraryFailure.permissionInsufficient }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
              album.canPerform(.removeContent) else { throw PhotoLibraryFailure.albumNotWritable }
        let uniqueIDs = Array(Set(assetIDs)).sorted()
        let members = PHAsset.fetchAssets(in: album, options: nil)
        var memberByID: [String: PHAsset] = [:]
        members.enumerateObjects { asset, _, _ in memberByID[asset.localIdentifier] = asset }
        let removable = uniqueIDs.compactMap { memberByID[$0] }
        let removableIDs = Set(removable.map(\.localIdentifier))
        let missingIDs = uniqueIDs.filter { !removableIDs.contains($0) }
        guard !removable.isEmpty else {
            return UndoResult(
                removedAssetIDs: [],
                missingAssetIDs: missingIDs, failedAssetIDs: []
            )
        }
        var removedIDs: [String] = []
        var failedIDs: [String] = []
        for start in stride(from: 0, to: removable.count, by: 100) {
            let batch = Array(removable[start..<min(start + 100, removable.count)])
            do {
                try await remove(batch, from: album)
                removedIDs.append(contentsOf: batch.map(\.localIdentifier))
            } catch {
                for asset in batch {
                    do { try await remove([asset], from: album); removedIDs.append(asset.localIdentifier) }
                    catch { failedIDs.append(asset.localIdentifier) }
                }
            }
        }
        return UndoResult(
            removedAssetIDs: removedIDs.sorted(),
            missingAssetIDs: missingIDs, failedAssetIDs: failedIDs.sorted()
        )
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.snapshot = nil }
    }

    private func resolveAlbum(named name: String, createIfMissing: Bool) async throws -> PHAssetCollection {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", normalized)
        let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        if matches.count > 1 { throw PhotoLibraryFailure.albumAmbiguous(normalized) }
        if let existing = matches.firstObject { return existing }
        guard createIfMissing else { throw PhotoLibraryFailure.albumNotFound }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: normalized).placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier,
              let created = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotoLibraryFailure.albumCreationFailed
        }
        return created
    }

    private func add(_ assets: [PHAsset], to album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
        }
    }

    private func remove(_ assets: [PHAsset], from album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAccessLevel {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .full
        case .limited: .limited
        @unknown default: .restricted
        }
    }

    private static func describe(_ asset: PHAsset) -> AssetDescriptor {
        let subtype: String? = if asset.mediaSubtypes.contains(.photoScreenshot) {
            "screenshot"
        } else if asset.mediaSubtypes.contains(.photoLive) {
            "live_photo"
        } else {
            nil
        }
        return AssetDescriptor(
            id: asset.localIdentifier,
            kind: asset.mediaType == .video ? .video : .image,
            subtype: subtype,
            createdAt: asset.creationDate,
            modifiedAt: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            hasLocation: asset.location != nil
        )
    }
}

private extension ThumbnailContentMode {
    var photoKitContentMode: PHImageContentMode {
        switch self {
        case .fit: .aspectFit
        case .fill: .aspectFill
        }
    }
}
