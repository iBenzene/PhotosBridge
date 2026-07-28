//
//  LibraryView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct LibraryView: View {
    let model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        Group {
            if !model.authorization.canRead {
                ContentUnavailableView {
                    Label("需要照片权限", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("授权后才能浏览获准访问的照片。")
                } actions: {
                    if model.authorization == .notDetermined {
                        Button("授权") { Task { await model.requestPhotoAccess() } }
                    }
                }
            } else if model.assets.isEmpty && !model.isLoading {
                ContentUnavailableView("没有可见照片", systemImage: "photo.on.rectangle")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(model.assets) { asset in
                            AssetCell(
                                asset: asset,
                                client: model.photoLibrary,
                                selected: model.selectedAssetIDs.contains(asset.id),
                                allowsNetwork: model.allowsICloudDownload
                            ) {
                                if model.selectedAssetIDs.contains(asset.id) { model.selectedAssetIDs.remove(asset.id) }
                                else { model.selectedAssetIDs.insert(asset.id) }
                            }
                        }
                    }
                    if model.nextCursor != nil {
                        Button(model.isLoading ? String(localized: "正在加载…") : String(localized: "加载更多")) {
                            Task { await model.loadNextPage() }
                        }
                        .disabled(model.isLoading)
                        .padding()
                    }
                }
            }
        }
        .navigationTitle("授权照片")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("重新加载", systemImage: "arrow.clockwise") { Task { await model.reloadLibrary() } }
            }
        }
    }
}

private struct AssetCell: View {
    let asset: AssetDescriptor
    let client: any PhotoLibraryClient
    let selected: Bool
    let allowsNetwork: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { Rectangle().fill(.quaternary).overlay { ProgressView() } }
                }
                .frame(minHeight: 104)
                .aspectRatio(1, contentMode: .fill)
                .clipped()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .shadow(radius: 2)
                    .padding(6)

                if asset.kind == .video {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.white).shadow(radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            image = try? await client.thumbnail(for: asset.id, targetSize: CGSize(width: 240, height: 240), allowsNetwork: allowsNetwork)
        }
        .accessibilityLabel(asset.kind == .video ? String(localized: "视频") : String(localized: "照片"))
        .accessibilityValue(selected ? String(localized: "已选择") : String(localized: "未选择"))
        .accessibilityIdentifier("asset-\(asset.id)")
    }
}
