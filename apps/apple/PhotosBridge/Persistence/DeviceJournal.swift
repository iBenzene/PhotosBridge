//
//  DeviceJournal.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation

struct DeviceJournalState: Codable {
    var pendingPlans: [WritePlan]
    var pendingHistoryAction: PendingHistoryAction?
    var historyRecords: [HistoryRecord]

    static let empty = DeviceJournalState(
        pendingPlans: [], pendingHistoryAction: nil, historyRecords: []
    )
}

@MainActor
final class DeviceJournal {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base.appending(path: "PhotosBridge/device-journal.json")
        }
    }

    func load() -> DeviceJournalState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(DeviceJournalState.self, from: data) else { return .empty }
        return state
    }

    func save(_ state: DeviceJournalState) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            assertionFailure("Device journal could not be persisted: \(error.localizedDescription)")
        }
    }
}
