//
//  HistoryView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct HistoryView: View {
    let model: AppModel

    var body: some View {
        Group {
            if !model.historyRecords.isEmpty {
                Form {
                    Section {
                        ForEach(model.historyRecords) { record in
                            NavigationLink {
                                HistoryDetailView(model: model, record: record)
                            } label: {
                                HistoryRow(record: record)
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
    }
}

struct HistoryDetailView: View {
    let model: AppModel
    let record: HistoryRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(spacing: 12) {
                        LabeledContent("目标相册", value: record.result.albumName)
                        LabeledContent("批次 ID") {
                            Text(record.batchID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label("基本信息", systemImage: "info.circle")
                }

                GroupBox {
                    VStack(spacing: 12) {
                        LabeledContent("请求", value: "\(record.result.counts.requested)")
                        LabeledContent("新增", value: "\(record.result.counts.added)")
                        LabeledContent("已存在", value: "\(record.result.counts.skippedExisting)")
                        LabeledContent("缺失", value: "\(record.result.counts.missing)")
                        LabeledContent("失败", value: "\(record.result.counts.failed)")
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

                if record.isUndoable {
                    Button("创建撤销计划", role: .destructive) {
                        model.makeUndoPlan(for: record.id)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle("历史详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord

    private var isUndone: Bool {
        record.undoResult != nil
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

                    Text(String(record.batchID.prefix(12)))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle")
                        Text("\(record.result.counts.requested)")
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                        Text("\(record.result.counts.added)")
                    }

                    if record.result.counts.failed > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("\(record.result.counts.failed)")
                        }
                        .foregroundStyle(.red)
                    }

                    if let undo = record.undoResult {
                        Spacer()
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "已撤销 (%lld张)"),
                                Int64(undo.removed)
                            )
                        )
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
