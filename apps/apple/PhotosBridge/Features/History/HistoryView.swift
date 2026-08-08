//
//  HistoryView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct HistoryView: View {
    let model: AppModel
    @State private var recordToDelete: HistoryRecord?

    var body: some View {
        Group {
            if !model.historyRecords.isEmpty {
                Form {
                    Section {
                        ForEach(model.historyRecords) { record in
                            NavigationLink {
                                HistoryDetailView(model: model, recordID: record.id)
                            } label: {
                                HistoryRow(record: record)
                            }
                            .swipeActions(edge: .leading) {
                                if record.isRestorable {
                                    Button {
                                        model.restoreHistoryRecord(id: record.id)
                                    } label: {
                                        Label("恢复", systemImage: "arrow.uturn.forward")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    recordToDelete = record
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .accessibilityIdentifier("history-record-\(record.id.uuidString)")
                        }
                    } header: {
                        frame(height: 6)
                    }
                }
            } else {
                ContentUnavailableView("暂无历史", systemImage: "clock")
            }
        }
        .navigationTitle("历史")
        .confirmationDialog(
            "确定要删除该历史记录吗？",
            isPresented: Binding(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let record = recordToDelete {
                    model.deleteHistoryRecord(id: record.id)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

struct HistoryDetailView: View {
    let model: AppModel
    let recordID: UUID

    private var record: HistoryRecord? {
        model.historyRecords.first { $0.id == recordID }
    }

    var body: some View {
        Group {
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        GroupBox {
                            VStack(spacing: 12) {
                                LabeledContent("目标相册", value: record.result.albumName)
                                LabeledContent("记录 ID") {
                                    Text(record.id.uuidString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } label: {
                            Label("基本信息", systemImage: "info.circle")
                        }

                        GroupBox {
                            VStack(spacing: 12) {
                                LabeledContent("请求", value: "\(record.result.requested)")
                                LabeledContent("新增", value: "\(record.result.added)")
                                LabeledContent("已存在", value: "\(record.result.alreadyPresent)")
                                LabeledContent("缺失", value: "\(record.result.missing)")
                                LabeledContent("失败", value: "\(record.result.failed)")
                            }
                        } label: {
                            Label("执行统计", systemImage: "chart.bar")
                        }

                        if let undo = record.undoResult {
                            GroupBox {
                                VStack(spacing: 12) {
                                    LabeledContent("已移除相册关系", value: "\(undo.removed)")
                                    LabeledContent("撤销失败", value: "\(undo.failed)")
                                }
                            } label: {
                                Label("撤销结果", systemImage: "arrow.uturn.backward")
                            }
                        }

                        if let restore = record.restoreResult {
                            GroupBox {
                                VStack(spacing: 12) {
                                    LabeledContent("已恢复相册关系", value: "\(restore.recoveredAssetIDs.count)")
                                    LabeledContent("恢复失败", value: "\(restore.failed)")
                                    LabeledContent("恢复缺失", value: "\(restore.missing)")
                                }
                            } label: {
                                Label("恢复结果", systemImage: "arrow.uturn.forward")
                            }
                        }

                        if record.isUndoable {
                            Button("创建撤销计划", role: .destructive) {
                                model.beginUndo(for: record.id)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        } else if record.isRestorable {
                            Button("恢复", systemImage: "arrow.uturn.forward") {
                                model.restoreHistoryRecord(id: record.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("历史记录不存在", systemImage: "clock.badge.xmark")
            }
        }
        .navigationTitle("历史详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord

    private var isUndone: Bool {
        record.isRestorable
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isUndone ? Color.orange.opacity(0.12) : Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)

                Image(systemName: isUndone ? "arrow.uturn.backward" : "photo.stack.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isUndone ? Color.orange : Color.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.result.albumName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(String(record.id.uuidString.prefix(12)))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle")
                        Text("\(record.result.requested)")
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                        Text("\(record.result.added)")
                    }

                    if record.result.failed > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("\(record.result.failed)")
                        }
                        .foregroundStyle(.red)
                    }

                    if record.isRestorable {
                        Spacer()
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "已撤销 (%lld张)"),
                                Int64(record.restorableAssetIDs.count)
                            )
                        )
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                    } else if let restore = record.restoreResult {
                        Spacer()
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "已恢复 (%lld张)"),
                                Int64(restore.recoveredAssetIDs.count)
                            )
                        )
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
