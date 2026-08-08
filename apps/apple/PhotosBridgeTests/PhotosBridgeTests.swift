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
            id: "plan_1", contentHash: String(repeating: "a", count: 64), serverURL: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            summary: "  本机验证  ",
            targetAlbumName: " Photos Bridge Test ",
            createAlbumIfMissing: true,
            assetIDs: ["asset-b", "asset-a", "asset-b"]
        )

        #expect(plan.summary == "本机验证")
        #expect(plan.targetAlbumName == "Photos Bridge Test")
        #expect(plan.assetIDs == ["asset-a", "asset-b"])
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

    @Test @MainActor func protocolEnvelopeAcceptsServerDatesWithFractionalSeconds() throws {
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
        let (model, fileURL) = Self.makeTestModel(client: client)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await model.loadNextPage()
        await model.loadNextPage()

        #expect(model.assets.map(\.id) == ["asset-a", "asset-b", "asset-c"])
        #expect(model.nextCursor == nil)
    }

    @Test @MainActor func deviceJournalRestoresPendingApprovalQueueAndSource() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-journal-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let plan = Self.plan(
            id: "plan_1", summary: "test", album: "album", assets: ["asset_1"],
            serverURL: "http://192.168.0.101:8787"
        )
        let result = OperationResult(
            id: UUID(), albumID: "album_1", albumName: "album",
            addedAssetIDs: ["asset_1"],
            alreadyPresentAssetIDs: [], missingAssetIDs: [], failedAssetIDs: []
        )
        journal.save(DeviceJournalState(
            pendingPlans: [plan], pendingHistoryAction: nil,
            historyRecords: [HistoryRecord(result: result, undoResult: nil)]
        ))

        let restored = journal.load()
        #expect(restored.pendingPlans == [plan])
        #expect(restored.pendingPlans.first?.serverURL == "http://192.168.0.101:8787")
        #expect(restored.historyRecords.count == 1)
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func appModelQueuesMultiplePendingPlans() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-plan-queue-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let model = AppModel(photoLibrary: MockPhotoLibraryClient(), journal: journal)

        let plan1 = Self.plan(id: "plan_1", summary: "first", album: "First", assets: ["asset-a"])
        let plan2 = Self.plan(id: "plan_2", summary: "second", album: "Second", assets: ["asset-b"])
        model.pendingPlans = [plan2, plan1]

        #expect(model.pendingPlans.map(\.targetAlbumName) == ["Second", "First"])
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func remotePlanExecutesOfflineWithoutServerReporting() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-offline-plan-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let client = MockPhotoLibraryClient()
        let model = AppModel(photoLibrary: client, journal: journal)
        let plan = Self.plan(
            id: "plan_1", summary: "remote", album: "Album", assets: ["asset-a"],
            serverURL: "https://temporary.example"
        )
        model.pendingPlans = [plan]

        await model.executePlan(id: plan.id)

        #expect(client.lastAddedAssetIDs == ["asset-a"])
        #expect(client.lastCreateIfMissing == true)
        #expect(model.pendingPlans.isEmpty)
        #expect(model.historyRecords.count == 1)
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func planPreservesDoNotCreateAlbumPolicyOffline() async {
        let client = MockPhotoLibraryClient()
        let (model, fileURL) = Self.makeTestModel(client: client)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let plan = Self.plan(
            id: "plan_existing_album_only", summary: "remote", album: "Existing",
            assets: ["asset-a"], createIfMissing: false
        )
        model.pendingPlans = [plan]

        await model.executePlan(id: plan.id)

        #expect(client.lastCreateIfMissing == false)
    }

    @Test @MainActor func remotePlanCanBeRejectedOffline() {
        let client = MockPhotoLibraryClient()
        let (model, fileURL) = Self.makeTestModel(client: client)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let plan = Self.plan(
            id: "plan_reject", summary: "remote", album: "Album", assets: ["asset-a"],
            serverURL: "https://temporary.example"
        )
        model.pendingPlans = [plan]

        model.rejectPlan(id: plan.id)

        #expect(model.pendingPlans.isEmpty)
    }

    @Test @MainActor func localUndoCanBeRejectedOffline() {
        let (model, fileURL) = Self.makeTestModel()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let record = Self.undoneHistoryRecord()
        model.historyRecords = [record]
        model.pendingHistoryAction = .undo(record.id)

        model.rejectPendingUndo()

        #expect(model.pendingHistoryAction == nil)
    }

    @Test @MainActor func appModelDeletesHistoryRecord() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-history-delete-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let model = AppModel(photoLibrary: MockPhotoLibraryClient(), journal: journal)

        let result1 = OperationResult(
            id: UUID(), albumID: "alb1", albumName: "Album1",
            addedAssetIDs: ["a1"],
            alreadyPresentAssetIDs: [], missingAssetIDs: [], failedAssetIDs: []
        )
        let result2 = OperationResult(
            id: UUID(), albumID: "alb2", albumName: "Album2",
            addedAssetIDs: ["a2"],
            alreadyPresentAssetIDs: [], missingAssetIDs: [], failedAssetIDs: []
        )
        let record1 = HistoryRecord(result: result1, undoResult: nil)
        let record2 = HistoryRecord(result: result2, undoResult: nil)

        model.historyRecords = [record1, record2]

        model.deleteHistoryRecord(id: record1.id)
        #expect(model.historyRecords.count == 1)
        #expect(model.historyRecords.first?.id == record2.id)
        #expect(journal.load().historyRecords.count == 1)

        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func restorePlanMirrorsTheActualUndoWithoutMutatingHistory() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-restore-plan-\(UUID().uuidString).json")
        let journal = DeviceJournal(fileURL: fileURL)
        let model = AppModel(photoLibrary: MockPhotoLibraryClient(), journal: journal)
        let result = OperationResult(
            id: UUID(), albumID: "album-original", albumName: "Renamed Album",
            addedAssetIDs: ["a", "b", "c"],
            alreadyPresentAssetIDs: [], missingAssetIDs: [], failedAssetIDs: []
        )
        let undo = UndoResult(
            removedAssetIDs: ["a", "c"],
            missingAssetIDs: [], failedAssetIDs: ["b"]
        )
        let record = HistoryRecord(result: result, undoResult: undo)
        model.historyRecords = [record]

        model.restoreHistoryRecord(id: record.id)

        #expect(model.pendingPlans.isEmpty)
        #expect(model.pendingHistoryAction == .restore(record.id))
        #expect(model.historyRecords.first?.undoResult == undo)
        #expect(model.historyRecords.first?.restoreResult == nil)
        let restoredModel = AppModel(photoLibrary: MockPhotoLibraryClient(), journal: journal)
        #expect(restoredModel.pendingHistoryAction == model.pendingHistoryAction)
        #expect(restoredModel.historyRecords.first?.undoResult == undo)
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test @MainActor func cancellingRestoreKeepsTheUndoRestorable() {
        let (model, fileURL) = Self.makeTestModel()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let record = Self.undoneHistoryRecord()
        model.historyRecords = [record]
        model.restoreHistoryRecord(id: record.id)

        model.rejectPendingRestore()

        #expect(model.pendingHistoryAction == nil)
        #expect(model.historyRecords.first?.isRestorable == true)
        #expect(model.historyRecords.first?.undoResult == record.undoResult)
    }

    @Test @MainActor func executingRestoreUpdatesTheSameHistoryRecord() async {
        let client = MockPhotoLibraryClient()
        client.nextRestoreResult = RestoreResult(
            addedAssetIDs: ["asset-a"], alreadyPresentAssetIDs: ["asset-b"],
            missingAssetIDs: [], failedAssetIDs: []
        )
        let (model, fileURL) = Self.makeTestModel(client: client)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let record = Self.undoneHistoryRecord()
        model.historyRecords = [record]
        model.restoreHistoryRecord(id: record.id)

        await model.executePendingRestore()

        #expect(client.lastRestoreAlbumID == "album_1")
        #expect(client.lastRestoreAssetIDs == ["asset-a", "asset-b"])
        #expect(model.pendingHistoryAction == nil)
        #expect(model.historyRecords.count == 1)
        #expect(model.historyRecords.first?.undoResult == record.undoResult)
        #expect(model.historyRecords.first?.restoreResult?.recoveredAssetIDs == ["asset-a", "asset-b"])
        #expect(model.historyRecords.first?.isRestorable == false)
        #expect(model.historyRecords.first?.isUndoable == true)
    }

    @Test @MainActor func planSourceUsesStoredServerAndNeverCurrentPairingFallback() {
        let (model, fileURL) = Self.makeTestModel()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let storedSource = Self.plan(
            id: "plan_source", summary: "source", album: "Album", assets: ["asset-a"],
            serverURL: "http://192.168.0.101:8787/"
        )
        let unknownSource = Self.plan(
            id: "plan_unknown", summary: "source", album: "Album", assets: ["asset-a"]
        )
        let otherSource = Self.plan(
            id: "plan_other", summary: "source", album: "Album", assets: ["asset-a"],
            serverURL: "http://192.168.1.1:8787"
        )

        #expect(PlanApprovalView(model: model, plan: storedSource).sourceServerName == "http://192.168.0.101:8787")
        #expect(PlanApprovalView(model: model, plan: otherSource).sourceServerName == "http://192.168.1.1:8787")
        #expect(PlanApprovalView(model: model, plan: unknownSource).sourceServerName == String(localized: "未知来源"))
    }

    @Test @MainActor func partialRestoreRetriesOnlyUnrecoveredAssets() async {
        let client = MockPhotoLibraryClient()
        client.nextRestoreResult = RestoreResult(
            addedAssetIDs: ["asset-a"], alreadyPresentAssetIDs: [],
            missingAssetIDs: ["asset-b"], failedAssetIDs: []
        )
        let (model, fileURL) = Self.makeTestModel(client: client)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let record = Self.undoneHistoryRecord()
        model.historyRecords = [record]
        model.restoreHistoryRecord(id: record.id)
        await model.executePendingRestore()

        model.restoreHistoryRecord(id: record.id)

        #expect(model.pendingHistoryAction == .restore(record.id))
        #expect(model.historyRecords.first?.restorableAssetIDs == ["asset-b"])
        #expect(model.historyRecords.first?.isRestorable == true)
    }

    @MainActor private static func makeTestModel() -> (AppModel, URL) {
        makeTestModel(client: MockPhotoLibraryClient())
    }

    @MainActor private static func makeTestModel(client: MockPhotoLibraryClient) -> (AppModel, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "photos-bridge-model-\(UUID().uuidString).json")
        return (AppModel(photoLibrary: client, journal: DeviceJournal(fileURL: fileURL)), fileURL)
    }

    private static func undoneHistoryRecord() -> HistoryRecord {
        let result = OperationResult(
            id: UUID(), albumID: "album_1", albumName: "Album",
            addedAssetIDs: ["asset-a", "asset-b"],
            alreadyPresentAssetIDs: [], missingAssetIDs: [], failedAssetIDs: []
        )
        return HistoryRecord(
            result: result,
            undoResult: UndoResult(
                removedAssetIDs: ["asset-a", "asset-b"],
                missingAssetIDs: [], failedAssetIDs: []
            )
        )
    }

    private static func plan(
        id: String,
        summary: String,
        album: String,
        assets: [String],
        serverURL: String? = nil,
        createIfMissing: Bool = true
    ) -> WritePlan {
        WritePlan(
            id: id, contentHash: String(repeating: "a", count: 64), serverURL: serverURL,
            summary: summary, targetAlbumName: album,
            createAlbumIfMissing: createIfMissing, assetIDs: assets
        )
    }
}



@MainActor
private final class MockPhotoLibraryClient: PhotoLibraryClient {
    private var page = 0
    var nextRestoreResult: RestoreResult?
    private(set) var lastRestoreAssetIDs: [String]?
    private(set) var lastRestoreAlbumID: String?
    private(set) var lastAddedAssetIDs: [String]?
    private(set) var lastCreateIfMissing: Bool?

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

    func add(assetIDs: [String], toAlbumNamed albumName: String, createIfMissing: Bool) async throws -> OperationResult {
        lastAddedAssetIDs = assetIDs
        lastCreateIfMissing = createIfMissing
        return OperationResult(
            id: UUID(), albumID: "album", albumName: albumName,
            addedAssetIDs: assetIDs,
            alreadyPresentAssetIDs: [], missingAssetIDs: [], failedAssetIDs: []
        )
    }

    func restore(assetIDs: [String], toAlbumID albumID: String) async throws -> RestoreResult {
        lastRestoreAssetIDs = assetIDs
        lastRestoreAlbumID = albumID
        return nextRestoreResult ?? RestoreResult(
            addedAssetIDs: assetIDs, alreadyPresentAssetIDs: [],
            missingAssetIDs: [], failedAssetIDs: []
        )
    }

    func remove(assetIDs: [String], fromAlbumID albumID: String) async throws -> UndoResult {
        UndoResult(removedAssetIDs: assetIDs, missingAssetIDs: [], failedAssetIDs: [])
    }

    private func asset(_ id: String) -> AssetDescriptor {
        AssetDescriptor(
            id: id, kind: .image, subtype: nil, createdAt: nil, modifiedAt: nil,
            pixelWidth: 100, pixelHeight: 100, duration: 0,
            isFavorite: false, isHidden: false, hasLocation: false
        )
    }
}
