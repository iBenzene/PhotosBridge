//
//  PlanApprovalView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct PlanApprovalView: View {
    let model: AppModel
    let item: PendingWritePlan
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var plan: WritePlan { item.plan }
    private var sourceServerName: String {
        let rawURL: String? = item.remoteContext?.serverURL ?? model.serverConnection.server?.baseURL.absoluteString
        guard let rawURL, !rawURL.isEmpty else { return String(localized: "未知服务器") }
        return rawURL.hasSuffix("/") ? String(rawURL.dropLast()) : rawURL
    }
    private var photoColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 2),
            count: horizontalSizeClass == .regular ? 5 : 3
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(spacing: 12) {
                        LabeledContent("相册", value: plan.targetAlbumName)
                        LabeledContent("候选照片", value: "\(plan.assetIDs.count)")
                        LabeledContent("来源", value: sourceServerName)
                        LabeledContent("创建时间") { Text(plan.createdAt, style: .date) }
                        LabeledContent("有效期") {
                            if plan.isExpired { Text("已过期").foregroundStyle(.red) }
                            else { Text(plan.expiresAt, style: .relative) }
                        }
                        LabeledContent("计划哈希") {
                            Text(item.remoteContext?.contentHash ?? plan.contentHash)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                } label: {
                    Label("写入计划", systemImage: "checklist")
                }

                if !plan.summary.isEmpty {
                    GroupBox {
                        Text(plan.summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label("说明", systemImage: "text.alignleft")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("候选照片").font(.headline)
                    LazyVGrid(columns: photoColumns, spacing: 2) {
                        ForEach(plan.assetIDs, id: \.self) { assetID in
                            PlanThumbnailView(
                                assetID: assetID,
                                client: model.photoLibrary,
                                allowsNetwork: model.allowsICloudDownload
                            )
                        }
                    }
                }

                Text("批准后只会把已有照片加入相册，不会复制、编辑或删除原始照片。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("审核计划")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("批准并执行") {
                    Task {
                        await model.executePlan(id: item.id)
                        if !model.pendingPlans.contains(where: { $0.id == item.id }) { dismiss() }
                    }
                }
                .disabled(model.isLoading || plan.isExpired || !model.authorization.canRead)
            }
        }
    }
}

struct PendingPlansView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.pendingPlans.isEmpty {
                emptyState
            } else {
                Form {
                    if !model.authorization.canRead {
                        Section {
                            Label("需要照片权限才能检查或执行计划", systemImage: "photo.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section {
                        ForEach(model.pendingPlans) { item in
                            NavigationLink {
                                PlanApprovalView(model: model, item: item)
                            } label: {
                                PendingPlanRow(item: item)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        await model.rejectPlan(id: item.id)
                                    }
                                } label: {
                                    Label("拒绝", systemImage: "trash")
                                }
                            }
                            .accessibilityIdentifier("pending-plan-\(item.id.uuidString)")
                        }
                    } header: {
                        frame(height: 6)
                    }
                }
            }
        }
        .navigationTitle("计划")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.authorization.canRead {
            ContentUnavailableView {
                Label("需要照片权限", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Photos Bridge 需要访问您允许的照片，才能检查和执行计划。")
            } actions: {
                if model.authorization == .notDetermined {
                    Button("授权照片访问") { Task { await model.requestPhotoAccess() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("前往设置") { model.selectedSection = .settings }
                }
            }
        } else {
            ContentUnavailableView {
                Label("暂无计划", systemImage: "checklist")
            } description: {
                Text("来自服务器的计划会保存在这里，供您稍后审核。")
            }
        }
    }
}

private struct PendingPlanRow: View {
    let item: PendingWritePlan

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.plan.isExpired ? Color.red.opacity(0.12) : Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)

                Image(systemName: item.plan.isExpired ? "clock.badge.exclamationmark" : "checklist")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(item.plan.isExpired ? Color.red : Color.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.plan.targetAlbumName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    if item.plan.isExpired {
                        Text("已过期")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    } else {
                        Text(item.plan.expiresAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !item.plan.summary.isEmpty {
                    Text(item.plan.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%lld 张照片"),
                            Int64(item.plan.assetIDs.count)
                        )
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MetadataValue: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PlanThumbnailView: View {
    let assetID: String
    let client: any PhotoLibraryClient
    let allowsNetwork: Bool
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary).overlay { ProgressView() }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.width)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: assetID) {
            image = try? await client.thumbnail(
                for: assetID,
                targetSize: CGSize(width: 180, height: 180),
                allowsNetwork: allowsNetwork
            )
        }
        .accessibilityIdentifier("plan-asset-\(assetID)")
    }
}
