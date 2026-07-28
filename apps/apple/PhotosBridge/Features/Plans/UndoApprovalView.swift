//
//  UndoApprovalView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct UndoApprovalView: View {
    let model: AppModel
    let undo: UndoPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("批次", value: String(undo.batchID.prefix(18)) + "…")
                    LabeledContent("相册", value: undo.albumName)
                    LabeledContent("成员关系", value: "\(undo.assetIDs.count)")
                } header: {
                    Text("撤销范围")
                } footer: {
                    Text("撤销只会移除本批次新增的相册成员关系，不会删除原始照片，也不会影响其他相册。")
                }
            }
            .navigationTitle("批准撤销计划")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("拒绝", role: .destructive) { Task { await model.rejectPendingUndo(); dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("批准并撤销") { Task { await model.executePendingUndo(); dismiss() } }
                }
            }
        }
    }
}
