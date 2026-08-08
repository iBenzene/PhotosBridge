//
//  AppModel.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let photoLibrary: any PhotoLibraryClient
    let serverConnection = ServerConnection()
    private let credentialsStore = CredentialsStore()
    private let journal: DeviceJournal

    var authorization: PhotoAccessLevel = .notDetermined
    var assets: [AssetDescriptor] = []
    var albums: [AlbumDescriptor] = []
    var snapshotID: String?
    var nextCursor: String?
    var isLoading = false
    var errorMessage: String?
    var pendingPlans: [WritePlan] = []
    var pendingHistoryAction: PendingHistoryAction?
    var historyRecords: [HistoryRecord] = []
    var selectedSection: AppSection = .plans
    var allowsICloudDownload = false
    var allowsThumbnailTransfer = true

    init(photoLibrary: (any PhotoLibraryClient)? = nil, journal: DeviceJournal? = nil) {
        let resolvedPhotoLibrary = photoLibrary ?? PhotoKitLibraryClient()
        let resolvedJournal = journal ?? DeviceJournal()
        self.photoLibrary = resolvedPhotoLibrary
        self.journal = resolvedJournal
        authorization = resolvedPhotoLibrary.authorizationLevel()
        let restored = resolvedJournal.load()
        pendingPlans = restored.pendingPlans
        pendingHistoryAction = restored.pendingHistoryAction
        historyRecords = restored.historyRecords
        serverConnection.onEnvelope = { [weak self] envelope in
            await self?.handle(envelope)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), pendingPlans.isEmpty {
            let demoPlan = WritePlan(
                id: "demo-plan-id",
                contentHash: String(repeating: "0", count: 64),
                serverURL: "http://192.168.0.12:8787",
                summary: String(localized: "UI测试演示计划"),
                targetAlbumName: "Photos Bridge Test",
                createAlbumIfMissing: true,
                assetIDs: ["demo-1"]
            )
            pendingPlans = [demoPlan]
        }
    }

    func start() async {
        authorization = photoLibrary.authorizationLevel()
        if authorization.canRead { await reloadLibrary() }
        if let (server, secret) = credentialsStore.load() {
            serverConnection.connect(server: server, secret: secret)
        }
    }

    func pair(serverURL: String, token: String, displayName: String, capabilities: [String]) async {
        do {
            guard let url = URL(string: serverURL), let scheme = url.scheme,
                  ["http", "https"].contains(scheme) else {
                throw ServerConnectionFailure.pairingRejected
            }
            let (server, secret) = try await serverConnection.pair(
                baseURL: url, token: token, displayName: displayName, capabilities: capabilities
            )
            try credentialsStore.save(server: server, secret: secret)
            serverConnection.connect(server: server, secret: secret)
        } catch { errorMessage = error.localizedDescription }
    }

    func forgetServer() async {
        credentialsStore.clear()
        await serverConnection.revokePairing()
    }

    func requestPhotoAccess() async {
        authorization = await photoLibrary.requestAuthorization()
        if authorization.canRead { await reloadLibrary() }
    }

    func refreshPhotoAccess() async {
        let updated = photoLibrary.authorizationLevel()
        guard updated != authorization else { return }
        authorization = updated
        if updated.canRead { await reloadLibrary() }
        else { assets = []; albums = [] }
    }

    func manageLimitedPhotoAccess() {
        photoLibrary.presentLimitedLibraryPicker()
    }

    func reloadLibrary() async {
        snapshotID = nil
        nextCursor = nil
        assets = []
        await loadNextPage()
        await loadAlbums()
    }

    func loadNextPage() async {
        guard authorization.canRead, !isLoading else { return }
        if snapshotID != nil, nextCursor == nil { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await photoLibrary.assetPage(snapshotID: snapshotID, cursor: nextCursor, limit: 100)
            snapshotID = page.snapshotID
            nextCursor = page.nextCursor
            assets.append(contentsOf: page.items.filter { item in !assets.contains(where: { $0.id == item.id }) })
        } catch PhotoLibraryFailure.snapshotInvalidated {
            snapshotID = nil
            nextCursor = nil
            assets = []
            isLoading = false
            await loadNextPage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadAlbums() async {
        guard authorization.canRead else { return }
        do { albums = try await photoLibrary.albums() }
        catch { errorMessage = error.localizedDescription }
    }

    func rejectPlan(id: String) {
        guard pendingPlans.contains(where: { $0.id == id }) else { return }
        pendingPlans.removeAll { $0.id == id }
        persistJournal()
    }

    func executePlan(id: String) async {
        guard let plan = pendingPlans.first(where: { $0.id == id }) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await photoLibrary.add(
                assetIDs: plan.assetIDs,
                toAlbumNamed: plan.targetAlbumName,
                createIfMissing: plan.createAlbumIfMissing
            )
            historyRecords.insert(HistoryRecord(result: result, undoResult: nil), at: 0)
            if historyRecords.count > 100 { historyRecords.removeLast(historyRecords.count - 100) }
            pendingPlans.removeAll { $0.id == id }
            persistJournal()
            await loadAlbums()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginUndo(for recordID: UUID) {
        guard let record = historyRecords.first(where: { $0.id == recordID }),
              record.isUndoable else { return }
        pendingHistoryAction = .undo(recordID)
        persistJournal()
    }

    func restoreHistoryRecord(id: UUID) {
        guard pendingHistoryAction == nil,
              let record = historyRecords.first(where: { $0.id == id }),
              record.isRestorable else { return }
        pendingHistoryAction = .restore(record.id)
        persistJournal()
    }

    func rejectPendingRestore() {
        guard case .restore = pendingHistoryAction else { return }
        pendingHistoryAction = nil
        persistJournal()
    }

    func executePendingRestore() async {
        guard case .restore(let recordID) = pendingHistoryAction,
              let index = historyRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let albumID = historyRecords[index].result.albumID
        let assetIDs = historyRecords[index].restorableAssetIDs
        isLoading = true
        defer { isLoading = false }
        do {
            let attempt = try await photoLibrary.restore(assetIDs: assetIDs, toAlbumID: albumID)
            let merged = historyRecords[index].restoreResult?.merging(attempt) ?? attempt
            historyRecords[index].restoreResult = merged
            pendingHistoryAction = nil
            persistJournal()
            await loadAlbums()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteHistoryRecord(id: UUID) {
        historyRecords.removeAll { $0.id == id }
        if pendingHistoryAction?.recordID == id { pendingHistoryAction = nil }
        persistJournal()
    }

    func deleteHistoryRecords(at offsets: IndexSet) {
        let removedIDs = Set(offsets.map { historyRecords[$0].id })
        historyRecords.remove(atOffsets: offsets)
        if let recordID = pendingHistoryAction?.recordID, removedIDs.contains(recordID) {
            pendingHistoryAction = nil
        }
        persistJournal()
    }

    func rejectPendingUndo() {
        guard case .undo = pendingHistoryAction else { return }
        pendingHistoryAction = nil
        persistJournal()
    }

    func executePendingUndo() async {
        guard case .undo(let recordID) = pendingHistoryAction,
              let index = historyRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let albumID = historyRecords[index].result.albumID
        let assetIDs = historyRecords[index].result.addedAssetIDs
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await photoLibrary.remove(assetIDs: assetIDs, fromAlbumID: albumID)
            historyRecords[index].undoResult = result
            historyRecords[index].restoreResult = nil
            pendingHistoryAction = nil
            persistJournal()
            await loadAlbums()
        } catch { errorMessage = error.localizedDescription }
    }

    private func handle(_ envelope: ProtocolEnvelope) async {
        do {
            let payload: JSONValue
            switch envelope.type {
            case "assets.list.request":
                try requireCapability("library.metadata.read")
                let page = try await photoLibrary.assetPage(
                    snapshotID: envelope.payload["snapshot_id"]?.stringValue,
                    cursor: envelope.payload["cursor"]?.stringValue,
                    limit: Int(envelope.payload["limit"]?.stringValue ?? "100") ?? 100
                )
                payload = try .encode(page)
            case "assets.get.request":
                try requireCapability("library.metadata.read")
                guard let assetID = envelope.payload["asset_id"]?.stringValue else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "缺少 asset_id。"))
                }
                payload = try .encode(try await photoLibrary.asset(id: assetID))
            case "albums.list.request":
                try requireCapability("library.albums.read")
                payload = try .encode(["albums": try await photoLibrary.albums()])
            case "albums.assets.request":
                try requireCapability("library.albums.read")
                guard let albumID = envelope.payload["album_id"]?.stringValue else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "缺少 album_id。"))
                }
                payload = try .encode(["asset_ids": try await photoLibrary.assetIDs(inAlbum: albumID)])
            case "assets.thumbnail.request":
                try requireCapability("assets.thumbnail.read")
                guard allowsThumbnailTransfer else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "用户已关闭缩略图传输。"))
                }
                guard let assetID = envelope.payload["asset_id"]?.stringValue else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "缺少 asset_id。"))
                }
                let dimension = Double(envelope.payload["max_dimension"]?.stringValue ?? "768") ?? 768
                let contentModeValue = envelope.payload["content_mode"]?.stringValue ?? ThumbnailContentMode.fill.rawValue
                guard let contentMode = ThumbnailContentMode(rawValue: contentModeValue) else {
                    await serverConnection.sendResponse(
                        to: envelope,
                        type: "assets.thumbnail.error",
                        payload: .object([
                            "code": .string("INVALID_THUMBNAIL_CONTENT_MODE"),
                            "message": .string(
                                String(format: String(localized: "无效的 content_mode：%@。"), contentModeValue)
                            )
                        ])
                    )
                    return
                }
                let image = try await photoLibrary.thumbnail(
                    for: assetID,
                    targetSize: CGSize(width: dimension, height: dimension),
                    contentMode: contentMode,
                    allowsNetwork: allowsICloudDownload
                )
                guard let data = image.jpegData(compressionQuality: 0.86) else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "无法编码缩略图。"))
                }
                payload = .object([
                    "data_base64": .string(data.base64EncodedString()),
                    "mime_type": .string("image/jpeg"),
                    "width": .number(Double(image.size.width)),
                    "height": .number(Double(image.size.height))
                ])
            case "plans.delivery.request":
                try requireCapability("albums.membership.write")
                guard let planID = envelope.payload["plan_id"]?.stringValue,
                      let expectedHash = envelope.payload["content_hash"]?.stringValue,
                      let summary = envelope.payload["summary"]?.stringValue,
                      let targetAlbum = envelope.payload["target_album"],
                      let albumName = targetAlbum["name"]?.stringValue,
                      let createIfMissing = targetAlbum["create_if_missing"]?.boolValue,
                      let assetValues = envelope.payload["asset_ids"]?.arrayValue else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "远程计划内容不完整。"))
                }
                let assetIDs = assetValues.compactMap(\.stringValue)
                guard assetIDs.count == assetValues.count else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "远程计划包含无效的资源 ID。"))
                }
                if createIfMissing {
                    try requireCapability("albums.create")
                }
                let hashContent: JSONValue = .object([
                    "asset_ids": .array(assetIDs.map(JSONValue.string)),
                    "device_id": .string(envelope.deviceID),
                    "summary": .string(summary),
                    "target_album": .object([
                        "create_if_missing": .bool(createIfMissing),
                        "name": .string(albumName)
                    ])
                ])
                guard try hashContent.canonicalSHA256() == expectedHash else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "远程计划哈希不匹配。"))
                }
                let existingIndex = pendingPlans.firstIndex { $0.id == planID }
                let plan = WritePlan(
                    id: planID,
                    contentHash: expectedHash,
                    serverURL: serverConnection.server?.baseURL.absoluteString,
                    createdAt: envelope.payload["created_at"]?.stringValue.flatMap(ProtocolEnvelope.parseDate) ?? Date(),
                    summary: summary,
                    targetAlbumName: albumName,
                    createAlbumIfMissing: createIfMissing,
                    assetIDs: assetIDs
                )
                if let existingIndex { pendingPlans[existingIndex] = plan }
                else {
                    pendingPlans.insert(plan, at: 0)
                    if pendingPlans.count > 100 { pendingPlans.removeLast(pendingPlans.count - 100) }
                }
                selectedSection = .plans
                persistJournal()
                payload = .object(["stored": .bool(true), "plan_id": .string(planID)])
            default:
                await serverConnection.sendResponse(
                    to: envelope,
                    type: envelope.type.replacingOccurrences(of: ".request", with: ".error"),
                    payload: .object(["code": .string("MESSAGE_TYPE_UNSUPPORTED")])
                )
                return
            }
            await serverConnection.sendResponse(
                to: envelope,
                type: envelope.type.replacingOccurrences(of: ".request", with: ".response"),
                payload: payload
            )
        } catch {
            await serverConnection.sendResponse(
                to: envelope,
                type: envelope.type.replacingOccurrences(of: ".request", with: ".error"),
                payload: .object([
                    "code": .string("REQUEST_FAILED"),
                    "message": .string(error.localizedDescription)
                ])
            )
        }
    }

    private func persistJournal() {
        journal.save(DeviceJournalState(
            pendingPlans: pendingPlans,
            pendingHistoryAction: pendingHistoryAction,
            historyRecords: historyRecords
        ))
    }

    private func requireCapability(_ capability: String) throws {
        guard serverConnection.server?.grants(capability) == true else {
            throw PhotoLibraryFailure.photoKit(
                String(format: String(localized: "当前配对未授予能力：%@"), capability)
            )
        }
    }

}

enum AppSection: String, CaseIterable, Identifiable {
    case plans
    case history
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .plans: String(localized: "计划")
        case .history: String(localized: "历史")
        case .settings: String(localized: "设置")
        }
    }
    var icon: String {
        icon(isSelected: false)
    }
    var selectedIcon: String {
        icon(isSelected: true)
    }

    func icon(isSelected: Bool) -> String {
        switch self {
        case .plans:
            isSelected ? "list.bullet.clipboard.fill" : "list.bullet.clipboard"
        case .history:
            isSelected ? "clock.fill" : "clock"
        case .settings:
            isSelected ? "gearshape.fill" : "gearshape"
        }
    }
}
