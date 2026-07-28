//
//  PhotosBridgeTests.swift
//  PhotosBridgeTests
//
//  Created by 埃苯泽 on 29/7/2026.
//

import CoreGraphics
import Testing
import UIKit
@testable import PhotosBridge

struct PhotosBridgeTests {
    @Test func writePlanDeduplicatesAndSortsAssets() {
        let plan = WritePlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 0),
            summary: "  本机验证  ",
            targetAlbumName: " Photos Bridge Test ",
            assetIDs: ["asset-b", "asset-a", "asset-b"]
        )

        #expect(plan.summary == "本机验证")
        #expect(plan.targetAlbumName == "Photos Bridge Test")
        #expect(plan.assetIDs == ["asset-a", "asset-b"])
        #expect(plan.contentHash.count == 64)
    }

    @Test func writePlanHashIsIndependentOfAssetInputOrder() {
        let first = WritePlan(summary: "test", targetAlbumName: "album", assetIDs: ["b", "a"])
        let second = WritePlan(summary: "test", targetAlbumName: "album", assetIDs: ["a", "b", "a"])
        #expect(first.contentHash == second.contentHash)
    }

    @Test func photoAccessOnlyAllowsAuthorizedStates() {
        #expect(PhotoAccessLevel.full.canRead)
        #expect(PhotoAccessLevel.limited.canRead)
        #expect(!PhotoAccessLevel.denied.canRead)
        #expect(!PhotoAccessLevel.restricted.canRead)
        #expect(!PhotoAccessLevel.notDetermined.canRead)
    }

    @Test func localizationTitlesAreNonEmpty() {
        #expect(!AppSection.plans.title.isEmpty)
        #expect(!PhotoAccessLevel.full.title.isEmpty)
        #expect(!ConnectionStatus.connected.title.isEmpty)
        for section in AppSection.allCases {
            #expect(!section.icon.isEmpty)
            #expect(!section.selectedIcon.isEmpty)
            #expect(section.icon != section.selectedIcon)
        }
    }

    @Test func protocolCanonicalHashMatchesServerFixture() throws {
        let content: JSONValue = .object([
            "asset_ids": .array([.string("asset-a"), .string("asset-b")]),
            "device_id": .string("device-1"),
            "summary": .string("test"),
            "target_album": .object(["create_if_missing": .bool(true), "name": .string("Album")])
        ])
        #expect(try content.canonicalSHA256() == "ee93904abd462f0245f3cd569ace8a0fdeaee835d5ba6c8698bae14840999dd7")
    }

    @Test func protocolEnvelopeAcceptsServerDatesWithFractionalSeconds() throws {
        let data = Data(#"{"protocol_version":1,"message_id":"msg_1","correlation_id":null,"device_id":"device_1","type":"session.ready","sent_at":"2026-07-30T20:06:42.575Z","payload":{}}"#.utf8)
        let envelope = try ProtocolEnvelope.makeDecoder().decode(ProtocolEnvelope.self, from: data)

        #expect(envelope.type == "session.ready")
        #expect(envelope.sentAt.timeIntervalSince1970 > 0)
    }

    @Test func snapshotPaginationTraversesFiftyThousandResourcesInBoundedPages() throws {
        var cursor: String?
        var visited = 0
        var pageCount = 0
        repeat {
            let bounds = try SnapshotPageBounds.calculate(
                totalCount: 50_000, cursor: cursor, requestedLimit: 500
            )
            #expect(bounds.range.count <= 500)
            visited += bounds.range.count
            pageCount += 1
            cursor = bounds.nextCursor
        } while cursor != nil
        #expect(visited == 50_000)
        #expect(pageCount == 100)
    }

    @Test @MainActor func appModelDeduplicatesAssetsAcrossPages() async {
        let client = MockPhotoLibraryClient()
        let model = AppModel(photoLibrary: client)

        await model.loadNextPage()
        await model.loadNextPage()

        #expect(model.assets.map(\.id) == ["asset-a", "asset-b", "asset-c"])
        #expect(model.nextCursor == nil)
    }

    @Test @MainActor func deviceJournalRestoresPendingApprovalQueueAndCompletionReport() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-journal-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let context = RemotePlanContext(planID: "plan_1", operationID: "op_1", contentHash: "abc")
        let plan = WritePlan(summary: "test", targetAlbumName: "album", assetIDs: ["asset_1"])
        let result = OperationResult(
            id: UUID(), albumID: "album_1", albumName: "album",
            counts: .init(requested: 1, added: 1, skippedExisting: 0, missing: 0, failed: 0),
            addedAssetIDs: ["asset_1"], failedAssetIDs: []
        )
        let pending = PendingWritePlan(plan: plan, remoteContext: context)
        journal.save(DeviceJournalState(
            pendingPlans: [pending], pendingPlan: nil, remotePlanContext: nil, pendingUndo: nil,
            lastResult: result, lastBatchID: "batch_1", lastUndoResult: nil,
            activeOperation: context,
            pendingOperationReport: OperationCompletionReport(context: context, result: result, batchID: "batch_1"),
            pendingUndoReport: nil,
            historyRecords: [HistoryRecord(result: result, batchID: "batch_1", undoResult: nil)]
        ))

        let restored = journal.load()
        #expect(restored.pendingPlans == [pending])
        #expect(restored.pendingOperationReport?.batchID == "batch_1")
        #expect(restored.historyRecords?.count == 1)
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func appModelMigratesLegacySinglePendingPlanIntoQueue() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-legacy-journal-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let plan = WritePlan(summary: "legacy", targetAlbumName: "album", assetIDs: ["asset_1"])
        let context = RemotePlanContext(planID: "plan_legacy", operationID: "op_legacy", contentHash: "hash")
        journal.save(DeviceJournalState(
            pendingPlans: nil, pendingPlan: plan, remotePlanContext: context, pendingUndo: nil,
            lastResult: nil, lastBatchID: nil, lastUndoResult: nil, activeOperation: nil,
            pendingOperationReport: nil, pendingUndoReport: nil, historyRecords: []
        ))

        let model = AppModel(photoLibrary: MockPhotoLibraryClient(), journal: journal)
        #expect(model.pendingPlans == [PendingWritePlan(plan: plan, remoteContext: context)])
        #expect(journal.load().pendingPlan == nil)
        #expect(journal.load().pendingPlans == model.pendingPlans)
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func appModelMigratesLegacyPlanWhenStoredQueueIsEmpty() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-empty-queue-legacy-journal-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let plan = WritePlan(summary: "legacy", targetAlbumName: "album", assetIDs: ["asset_1"])
        let context = RemotePlanContext(planID: "plan_legacy", operationID: "op_legacy", contentHash: "hash")
        journal.save(DeviceJournalState(
            pendingPlans: [], pendingPlan: plan, remotePlanContext: context, pendingUndo: nil,
            lastResult: nil, lastBatchID: nil, lastUndoResult: nil, activeOperation: nil,
            pendingOperationReport: nil, pendingUndoReport: nil, historyRecords: []
        ))

        let model = AppModel(photoLibrary: MockPhotoLibraryClient(), journal: journal)
        #expect(model.pendingPlans == [PendingWritePlan(plan: plan, remoteContext: context)])
        #expect(journal.load().pendingPlan == nil)
        #expect(journal.load().pendingPlans == model.pendingPlans)
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func appModelQueuesMultiplePendingPlans() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-plan-queue-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let model = AppModel(photoLibrary: MockPhotoLibraryClient(), journal: journal)

        let plan1 = WritePlan(summary: "first", targetAlbumName: "First", assetIDs: ["asset-a"])
        let plan2 = WritePlan(summary: "second", targetAlbumName: "Second", assetIDs: ["asset-b"])
        model.pendingPlans = [PendingWritePlan(plan: plan2, remoteContext: nil), PendingWritePlan(plan: plan1, remoteContext: nil)]

        #expect(model.pendingPlans.map(\.plan.targetAlbumName) == ["Second", "First"])
        try? FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
private final class MockPhotoLibraryClient: PhotoLibraryClient {
    private var page = 0

    func authorizationLevel() -> PhotoAccessLevel { .full }
    func requestAuthorization() async -> PhotoAccessLevel { .full }
    func presentLimitedLibraryPicker() {}

    func assetPage(snapshotID: String?, cursor: String?, limit: Int) async throws -> AssetPage {
        defer { page += 1 }
        if page == 0 {
            return AssetPage(snapshotID: "snapshot", items: [asset("asset-a"), asset("asset-b")], nextCursor: "2")
        }
        return AssetPage(snapshotID: "snapshot", items: [asset("asset-b"), asset("asset-c")], nextCursor: nil)
    }

    func thumbnail(for assetID: String, targetSize: CGSize, allowsNetwork: Bool) async throws -> UIImage { UIImage() }
    func asset(id: String) async throws -> AssetDescriptor { asset(id) }
    func albums() async throws -> [AlbumDescriptor] { [] }
    func assetIDs(inAlbum albumID: String) async throws -> [String] { [] }

    func add(assetIDs: [String], toAlbumNamed albumName: String) async throws -> OperationResult {
        OperationResult(
            id: UUID(), albumID: "album", albumName: albumName,
            counts: .init(requested: assetIDs.count, added: assetIDs.count, skippedExisting: 0, missing: 0, failed: 0),
            addedAssetIDs: assetIDs, failedAssetIDs: []
        )
    }

    func remove(assetIDs: [String], fromAlbumID albumID: String) async throws -> UndoResult {
        UndoResult(requested: assetIDs.count, removed: assetIDs.count, missing: 0, failed: 0, removedAssetIDs: assetIDs)
    }

    private func asset(_ id: String) -> AssetDescriptor {
        AssetDescriptor(
            id: id, kind: .image, subtype: nil, createdAt: nil, modifiedAt: nil,
            pixelWidth: 100, pixelHeight: 100, duration: 0,
            isFavorite: false, isHidden: false, hasLocation: false
        )
    }
}
