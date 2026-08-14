//
//  UndoApprovalView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct HistoryActionApprovalView: View {
    let model: AppModel
    let action: PendingHistoryAction
    @Environment(\.dismiss) private var dismiss

    private var record: HistoryRecord? {
        model.historyRecords.first { $0.id == action.recordID }
    }

    private var isRestore: Bool {
        if case .restore = action { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                if let record {
                    Section {
                        LabeledContent("记录", value: String(record.id.uuidString.prefix(18)) + "…")
                        LabeledContent("相册", value: record.result.albumName)
                        LabeledContent(
                            "成员关系",
                            value: "\(isRestore ? record.restorableAssetIDs.count : record.result.addedAssetIDs.count)"
                        )
                    } header: {
                        Text(isRestore ? "恢复范围" : "撤销范围")
                    } footer: {
                        Text(isRestore
                             ? "恢复只会重新加入本次撤销实际移除的相册成员关系，并写回原相册。"
                             : "撤销只会移除本次执行新增的相册成员关系，不会删除原始照片，也不会影响其他相册。")
                    }
                } else {
                    ContentUnavailableView("历史记录不存在", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle(isRestore ? "批准恢复撤销" : "批准撤销")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRestore ? "取消" : "拒绝", role: isRestore ? .cancel : .destructive) {
                        if isRestore { model.rejectPendingRestore() }
                        else { model.rejectPendingUndo() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRestore ? "批准并恢复" : "批准并撤销") {
                        Task {
                            if isRestore { await model.executePendingRestore() }
                            else { await model.executePendingUndo() }
                            if model.pendingHistoryAction == nil { dismiss() }
                        }
                    }
                    .disabled(record == nil || model.isLoading || !model.authorization.canRead)
                }
            }
        }
    }
}
