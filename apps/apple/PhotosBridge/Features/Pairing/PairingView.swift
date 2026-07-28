//
//  PairingView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI

struct PairingView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = "http://127.0.0.1:8787"
    @State private var token = ""
    @State private var displayName = UIDevice.current.name
    @State private var showingScanner = false
    @State private var allowsMetadata = true
    @State private var allowsAlbums = true
    @State private var allowsThumbnails = true
    @State private var allowsAlbumWrites = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://server.example", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("一次性配对码", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("设备名称", text: $displayName)
                    Button("扫描配对二维码", systemImage: "qrcode.viewfinder") { showingScanner = true }
                        .disabled(!QRScannerView.isSupported)
                } header: {
                    Text("服务器")
                }
                Section {
                    Toggle("读取照片元数据", isOn: $allowsMetadata)
                    Toggle("读取相册", isOn: $allowsAlbums)
                    Toggle("传输受限缩略图", isOn: $allowsThumbnails)
                    Toggle("提交相册写入计划", isOn: $allowsAlbumWrites)
                } header: {
                    Text("授权能力")
                } footer: {
                    Text("相册写入默认关闭。启用后，每次计划仍必须在本设备上批准。")
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { payload in
                    serverURL = payload.serverURL.absoluteString
                    token = payload.pairingToken
                    showingScanner = false
                }
                .ignoresSafeArea()
            }
            .navigationTitle("配对服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("配对") {
                        performPairing()
                    }
                    .disabled(serverURL.isEmpty || token.isEmpty || displayName.isEmpty)
                }
            }
        }
    }

    private func performPairing() {
        guard !serverURL.isEmpty && !token.isEmpty && !displayName.isEmpty else { return }
        Task {
            var capabilities: [String] = []
            if allowsMetadata { capabilities.append("library.metadata.read") }
            if allowsAlbums { capabilities.append("library.albums.read") }
            if allowsThumbnails { capabilities.append("assets.thumbnail.read") }
            if allowsAlbumWrites {
                capabilities.append("albums.create")
                capabilities.append("albums.membership.write")
            }
            await model.pair(
                serverURL: serverURL, token: token, displayName: displayName,
                capabilities: capabilities
            )
            if model.errorMessage == nil { dismiss() }
        }
    }
}
