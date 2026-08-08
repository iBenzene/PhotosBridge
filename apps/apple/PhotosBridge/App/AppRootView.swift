//
//  AppRootView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI
import UIKit

struct AppRootView: View {
    @State private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let client: any PhotoLibraryClient = isUITesting ? DemoPhotoLibraryClient() : PhotoKitLibraryClient()
        let journal = isUITesting ? DeviceJournal(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "photos-bridge-ui-\(ProcessInfo.processInfo.processIdentifier).json")
        ) : nil
        _model = State(initialValue: AppModel(photoLibrary: client, journal: journal))
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List(selection: Binding<AppSection?>(
                        get: { model.selectedSection },
                        set: { if let section = $0 { model.selectedSection = section } }
                    )) {
                        ForEach(AppSection.allCases) { section in
                            Label(section.title, systemImage: section.icon(isSelected: model.selectedSection == section))
                                .tag(section)
                        }
                    }
                    .listStyle(.sidebar)
                } detail: {
                    NavigationStack {
                        sectionView(model.selectedSection)
                    }
                    .id(model.selectedSection)
                }
            } else {
                TabView(selection: $model.selectedSection) {
                    ForEach(AppSection.allCases) { section in
                        NavigationStack { sectionView(section) }
                            .background(TabBarIconConfigurator())
                            .tabItem {
                                Label(section.title, systemImage: section.icon)
                            }
                            .tag(section)
                    }
                }
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.serverConnection.resume()
                Task { await model.refreshPhotoAccess() }
            }
            else if phase == .background { model.serverConnection.pause() }
        }
        .alert("Photos Bridge", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("好", role: .cancel) {} } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .sheet(item: $model.pendingHistoryAction) { action in
            HistoryActionApprovalView(model: model, action: action)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .plans: PendingPlansView(model: model)
        case .history: HistoryView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

/// SwiftUI caches the `UITabBarItem` created from `.tabItem`, so changing the
/// label's system image with the selection does not update its selected image.
/// Configure both UIKit image states once and let `UITabBar` switch between them.
private struct TabBarIconConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TabBarIconConfiguratorViewController {
        TabBarIconConfiguratorViewController()
    }

    func updateUIViewController(
        _ uiViewController: TabBarIconConfiguratorViewController,
        context: Context
    ) {
        uiViewController.configureTabBarItems()
    }
}

private final class TabBarIconConfiguratorViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureTabBarItems()
    }

    func configureTabBarItems() {
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let tabBarController = sequence(first: self.parent, next: { $0?.parent })
                    .compactMap({ $0 as? UITabBarController })
                    .first,
                let items = tabBarController.tabBar.items,
                items.count == AppSection.allCases.count
            else { return }

            for (item, section) in zip(items, AppSection.allCases) {
                item.image = UIImage(systemName: section.icon)
                item.selectedImage = UIImage(systemName: section.selectedIcon)
            }
        }
    }
}
