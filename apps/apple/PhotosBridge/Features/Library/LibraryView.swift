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
                                allowsNetwork: model.allowsICloudDownload
                            )
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
    let allowsNetwork: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary).overlay { ProgressView() } }
            }
            .frame(minHeight: 104)
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            if asset.kind == .video {
                Image(systemName: "video.fill")
                    .foregroundStyle(.white).shadow(radius: 2)
                    .padding(6)
            }
        }
        .task(id: asset.id) {
            image = try? await client.thumbnail(
                for: asset.id,
                targetSize: CGSize(width: 240, height: 240),
                contentMode: .fill,
                allowsNetwork: allowsNetwork
            )
        }
        .accessibilityLabel(asset.kind == .video ? String(localized: "视频") : String(localized: "照片"))
        .accessibilityIdentifier("asset-\(asset.id)")
    }
}
