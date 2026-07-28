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
    var selectedAssetIDs = Set<String>()
    var snapshotID: String?
    var nextCursor: String?
    var isLoading = false
    var errorMessage: String?
    var lastResult: OperationResult?
    var pendingPlans: [PendingWritePlan] = []
    var pendingUndo: UndoPlan?
    var lastBatchID: String?
    var lastUndoResult: UndoResult?
    var activeOperation: RemotePlanContext?
    var pendingOperationReport: OperationCompletionReport?
    var pendingUndoReport: UndoCompletionReport?
    var historyRecords: [HistoryRecord] = []
    var selectedSection: AppSection = .plans
    var allowsICloudDownload = false
    var allowsThumbnailTransfer = true
    private var isRecoveringJournal = false

    init(photoLibrary: (any PhotoLibraryClient)? = nil, journal: DeviceJournal? = nil) {
        let resolvedPhotoLibrary = photoLibrary ?? PhotoKitLibraryClient()
        let resolvedJournal = journal ?? DeviceJournal()
        self.photoLibrary = resolvedPhotoLibrary
        self.journal = resolvedJournal
        authorization = resolvedPhotoLibrary.authorizationLevel()
        let restored = resolvedJournal.load()
        pendingPlans = restored.pendingPlans ?? []
        var migratedLegacyPlan = false
        if let legacyPlan = restored.pendingPlan {
            let legacyItem = PendingWritePlan(plan: legacyPlan, remoteContext: restored.remotePlanContext)
            let alreadyQueued = pendingPlans.contains {
                $0.id == legacyItem.id ||
                ($0.remoteContext?.planID != nil && $0.remoteContext?.planID == legacyItem.remoteContext?.planID)
            }
            if !alreadyQueued { pendingPlans.insert(legacyItem, at: 0) }
            migratedLegacyPlan = true
        }
        pendingUndo = restored.pendingUndo
        lastResult = restored.lastResult
        lastBatchID = restored.lastBatchID
        lastUndoResult = restored.lastUndoResult
        activeOperation = restored.activeOperation
        pendingOperationReport = restored.pendingOperationReport
        pendingUndoReport = restored.pendingUndoReport
        historyRecords = restored.historyRecords ?? restored.lastResult.map {
            [HistoryRecord(result: $0, batchID: restored.lastBatchID ?? "batch_legacy", undoResult: restored.lastUndoResult)]
        } ?? []
        serverConnection.onEnvelope = { [weak self] envelope in
            await self?.handle(envelope)
        }
        serverConnection.onConnected = { [weak self] in
            await self?.recoverJournalAfterConnection()
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), pendingPlans.isEmpty {
            let demoPlan = WritePlan(
                summary: String(localized: "UI测试演示计划"),
                targetAlbumName: "Photos Bridge Test",
                assetIDs: ["demo-1"]
            )
            let demoItem = PendingWritePlan(
                plan: demoPlan,
                remoteContext: RemotePlanContext(
                    planID: "demo-plan-id",
                    operationID: "demo-op-id",
                    contentHash: demoPlan.contentHash,
                    serverURL: "http://192.168.0.12:8787"
                )
            )
            pendingPlans = [demoItem]
        }
        if restored.pendingPlans == nil || migratedLegacyPlan { persistJournal() }
    }

    func start() async {
        authorization = photoLibrary.authorizationLevel()
        if authorization.canRead { await reloadLibrary() }
        if let (server, secret) = credentialsStore.load() {
            serverConnection.connect(server: server, secret: secret)
        }
    }

    private func recoverJournalAfterConnection() async {
        guard !isRecoveringJournal else { return }
        isRecoveringJournal = true
        defer { isRecoveringJournal = false }
        if let pendingOperationReport {
            if await sendOperationReport(pendingOperationReport) {
                self.pendingOperationReport = nil
                self.activeOperation = nil
                persistJournal()
            }
        } else if let activeOperation {
            let acknowledged = await serverConnection.sendEvent(type: "operation.unknown", payload: .object([
                "plan_id": .string(activeOperation.planID),
                "operation_id": .string(activeOperation.operationID),
                "reason": .string("app_terminated_during_photokit_commit")
            ]))
            if acknowledged { self.activeOperation = nil; persistJournal() }
        }
        if let pendingUndoReport, await sendUndoReport(pendingUndoReport) {
            self.pendingUndoReport = nil
            self.pendingUndo = nil
            persistJournal()
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
        else { assets = []; albums = []; selectedAssetIDs = [] }
    }

    func manageLimitedPhotoAccess() {
        photoLibrary.presentLimitedLibraryPicker()
    }

    func reloadLibrary() async {
        snapshotID = nil
        nextCursor = nil
        assets = []
        selectedAssetIDs = []
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

    func rejectPlan(id: UUID) async {
        guard let item = pendingPlans.first(where: { $0.id == id }) else { return }
        if let context = item.remoteContext {
            let acknowledged = await serverConnection.sendEvent(type: "plan.rejected", payload: .object([
                "plan_id": .string(context.planID), "operation_id": .string(context.operationID)
            ]))
            guard acknowledged else {
                errorMessage = String(localized: "服务器尚未确认拒绝结果，请保持连接后重试。")
                return
            }
        }
        pendingPlans.removeAll { $0.id == id }
        persistJournal()
    }

    func executePlan(id: UUID) async {
        guard let item = pendingPlans.first(where: { $0.id == id }) else { return }
        let plan = item.plan
        guard !plan.isExpired else {
            errorMessage = String(localized: "计划已经过期，请重新创建。")
            return
        }
        let context = item.remoteContext
        isLoading = true
        defer { isLoading = false }
        do {
            if let context {
                let acknowledged = await serverConnection.sendEvent(type: "operation.executing", payload: .object([
                    "plan_id": .string(context.planID), "operation_id": .string(context.operationID)
                ]))
                guard acknowledged else {
                    errorMessage = String(localized: "服务器尚未确认执行状态，照片库未被修改。")
                    return
                }
                activeOperation = context
                persistJournal()
            }
            lastResult = try await photoLibrary.add(assetIDs: plan.assetIDs, toAlbumNamed: plan.targetAlbumName)
            if let result = lastResult {
                let batchID = "batch_\(result.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
                lastBatchID = batchID
                historyRecords.insert(HistoryRecord(result: result, batchID: batchID, undoResult: nil), at: 0)
                if historyRecords.count > 100 { historyRecords.removeLast(historyRecords.count - 100) }
                if let context {
                    let report = OperationCompletionReport(context: context, result: result, batchID: batchID)
                    pendingOperationReport = report
                    persistJournal()
                    if await sendOperationReport(report) { activeOperation = nil; pendingOperationReport = nil }
                }
            }
            selectedAssetIDs = []
            pendingPlans.removeAll { $0.id == id }
            persistJournal()
            await loadAlbums()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func makeUndoPlan(for recordID: UUID) {
        guard let record = historyRecords.first(where: { $0.id == recordID }),
              let albumID = record.result.albumID, record.isUndoable else { return }
        pendingUndo = UndoPlan(
            id: UUID(), remoteID: nil,
            batchID: record.batchID,
            albumID: albumID, albumName: record.result.albumName, assetIDs: record.result.addedAssetIDs
        )
        persistJournal()
    }

    func rejectPendingUndo() async {
        if let remoteID = pendingUndo?.remoteID {
            let acknowledged = await serverConnection.sendEvent(
                type: "undo.rejected", payload: .object(["undo_plan_id": .string(remoteID)])
            )
            guard acknowledged else {
                errorMessage = String(localized: "服务器尚未确认拒绝结果，请保持连接后重试。")
                return
            }
        }
        pendingUndo = nil
        persistJournal()
    }

    func executePendingUndo() async {
        guard let undo = pendingUndo else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await photoLibrary.remove(assetIDs: undo.assetIDs, fromAlbumID: undo.albumID)
            lastUndoResult = result
            if let index = historyRecords.firstIndex(where: { $0.batchID == undo.batchID }) {
                historyRecords[index].undoResult = result
            }
            if let remoteID = undo.remoteID {
                let report = UndoCompletionReport(undoPlanID: remoteID, batchID: undo.batchID, result: result)
                pendingUndoReport = report
                persistJournal()
                if await sendUndoReport(report) { pendingUndoReport = nil }
            }
            pendingUndo = nil
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
                let image = try await photoLibrary.thumbnail(
                    for: assetID,
                    targetSize: CGSize(width: dimension, height: dimension),
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
            case "plans.approval.request":
                try requireCapability("albums.membership.write")
                guard let planID = envelope.payload["plan_id"]?.stringValue,
                      let operationID = envelope.payload["operation_id"]?.stringValue,
                      let expectedHash = envelope.payload["content_hash"]?.stringValue,
                      let summary = envelope.payload["summary"]?.stringValue,
                      let deviceID = envelope.payload["device_id"]?.stringValue,
                      let targetAlbum = envelope.payload["target_album"],
                      let albumName = targetAlbum["name"]?.stringValue,
                      let assetValues = envelope.payload["asset_ids"]?.arrayValue else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "远程计划内容不完整。"))
                }
                let assetIDs = assetValues.compactMap(\.stringValue)
                if targetAlbum["create_if_missing"]?.boolValue == true {
                    try requireCapability("albums.create")
                }
                let hashContent: JSONValue = .object([
                    "asset_ids": .array(assetIDs.map(JSONValue.string)),
                    "device_id": .string(deviceID),
                    "summary": .string(summary),
                    "target_album": .object([
                        "create_if_missing": .bool(targetAlbum["create_if_missing"]?.boolValue ?? false),
                        "name": .string(albumName)
                    ])
                ])
                guard try hashContent.canonicalSHA256() == expectedHash else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "远程计划哈希不匹配。"))
                }
                let existingIndex = pendingPlans.firstIndex { $0.remoteContext?.planID == planID }
                let plan = WritePlan(
                    id: existingIndex.map { pendingPlans[$0].id } ?? UUID(),
                    createdAt: envelope.payload["created_at"]?.stringValue.flatMap(ProtocolEnvelope.parseDate) ?? Date(),
                    expiresAt: envelope.payload["expires_at"]?.stringValue.flatMap(ProtocolEnvelope.parseDate),
                    summary: summary,
                    targetAlbumName: albumName,
                    assetIDs: assetIDs
                )
                let item = PendingWritePlan(
                    plan: plan,
                    remoteContext: RemotePlanContext(
                        planID: planID, operationID: operationID, contentHash: expectedHash,
                        serverURL: serverConnection.server?.baseURL.absoluteString
                    )
                )
                if let existingIndex { pendingPlans[existingIndex] = item }
                else {
                    pendingPlans.insert(item, at: 0)
                    if pendingPlans.count > 100 { pendingPlans.removeLast(pendingPlans.count - 100) }
                }
                selectedSection = .plans
                persistJournal()
                payload = .object(["accepted": .bool(true), "plan_id": .string(planID)])
            case "undo.approval.request":
                guard let undoID = envelope.payload["undo_plan_id"]?.stringValue,
                      let batchID = envelope.payload["batch_id"]?.stringValue,
                      let albumID = envelope.payload["target_album_id"]?.stringValue,
                      let expectedHash = envelope.payload["content_hash"]?.stringValue,
                      let values = envelope.payload["asset_ids"]?.arrayValue else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "撤销计划内容不完整。"))
                }
                let undoHashContent: JSONValue = .object([
                    "asset_ids": .array(values),
                    "batch_id": .string(batchID),
                    "target_album_id": .string(albumID)
                ])
                guard try undoHashContent.canonicalSHA256() == expectedHash else {
                    throw PhotoLibraryFailure.photoKit(String(localized: "撤销计划哈希不匹配。"))
                }
                pendingUndo = UndoPlan(
                    id: UUID(), remoteID: undoID, batchID: batchID, albumID: albumID,
                    albumName: String(localized: "目标相册"), assetIDs: values.compactMap(\.stringValue)
                )
                persistJournal()
                payload = .object(["accepted": .bool(true), "undo_plan_id": .string(undoID)])
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
                    "code": .string("PHOTOKIT_READ_FAILED"),
                    "message": .string(error.localizedDescription)
                ])
            )
        }
    }

    private func persistJournal() {
        journal.save(DeviceJournalState(
            pendingPlans: pendingPlans,
            pendingPlan: nil,
            remotePlanContext: nil,
            pendingUndo: pendingUndo,
            lastResult: lastResult,
            lastBatchID: lastBatchID,
            lastUndoResult: lastUndoResult,
            activeOperation: activeOperation,
            pendingOperationReport: pendingOperationReport,
            pendingUndoReport: pendingUndoReport,
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

    private func sendOperationReport(_ report: OperationCompletionReport) async -> Bool {
        await serverConnection.sendEvent(type: "operation.completed", payload: .object([
            "plan_id": .string(report.context.planID),
            "operation_id": .string(report.context.operationID),
            "batch_id": .string(report.batchID),
            "album_id": .string(report.result.albumID ?? ""),
            "counts": (try? .encode(report.result.counts)) ?? .object([:]),
            "added_asset_ids": (try? .encode(report.result.addedAssetIDs)) ?? .array([]),
            "failures": (try? .encode(report.result.failedAssetIDs)) ?? .array([])
        ]))
    }

    private func sendUndoReport(_ report: UndoCompletionReport) async -> Bool {
        await serverConnection.sendEvent(type: "undo.completed", payload: .object([
            "undo_plan_id": .string(report.undoPlanID), "batch_id": .string(report.batchID),
            "removed_asset_ids": (try? .encode(report.result.removedAssetIDs)) ?? .array([]),
            "counts": (try? .encode(report.result)) ?? .object([:])
        ]))
    }
}

struct RemotePlanContext: Equatable, Codable, Sendable {
    let planID: String
    let operationID: String
    let contentHash: String
    let serverURL: String?

    init(planID: String, operationID: String, contentHash: String, serverURL: String? = nil) {
        self.planID = planID
        self.operationID = operationID
        self.contentHash = contentHash
        self.serverURL = serverURL
    }
}

struct OperationCompletionReport: Equatable, Codable, Sendable {
    let context: RemotePlanContext
    let result: OperationResult
    let batchID: String
}

struct UndoCompletionReport: Equatable, Codable, Sendable {
    let undoPlanID: String
    let batchID: String
    let result: UndoResult
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
