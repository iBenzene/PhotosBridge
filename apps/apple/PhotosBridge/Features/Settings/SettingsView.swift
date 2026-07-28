//
//  SettingsView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showingPairing = false

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return String(format: String(localized: "Photos Bridge Version %@"), version)
    }

    var body: some View {
        Form {
            Section("照片") {
                LabeledContent("权限", value: model.authorization.title)
                if model.authorization == .limited {
                    Button("管理有限照片访问") { model.manageLimitedPhotoAccess() }
                } else if model.authorization == .denied || model.authorization == .restricted {
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Toggle("允许缩略图离开设备", isOn: $model.allowsThumbnailTransfer)
                Toggle("允许从 iCloud 下载", isOn: $model.allowsICloudDownload)
                if model.authorization.canRead {
                    NavigationLink("检查授权内容") { LibraryView(model: model) }
                }
            }
            Section {
                LabeledContent("状态", value: model.serverConnection.status.title)
                if let server = model.serverConnection.server {
                    LabeledContent("地址", value: server.baseURL.absoluteString)
                    LabeledContent("设备 ID", value: String(server.deviceID.prefix(18)) + "…")
                    ForEach(server.capabilities ?? [], id: \.self) { capability in
                        Label(capability, systemImage: "checkmark.shield")
                            .font(.caption)
                    }
                    Button("解除与此服务器的配对", role: .destructive) { Task { await model.forgetServer() } }
                } else {
                    Button("配对服务器") { showingPairing = true }
                }
            } header: {
                Text("服务器")
            } footer: {
                Text(versionText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showingPairing) { PairingView(model: model) }
    }
}
