//
//  CredentialsStore.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation
import Security

@MainActor
final class CredentialsStore {
    private let defaultsKey = "photosBridge.pairedServer"
    private let service = "com.ibenzene.PhotosBridge.device"

    func save(server: PairedServer, secret: String) throws {
        let serverData = try JSONEncoder().encode(server)
        let secretData = Data(secret.utf8)
        SecItemDelete(query(server.deviceID) as CFDictionary)
        var add = query(server.deviceID)
        add[kSecValueData as String] = secretData
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialFailure.keychain(status) }
        UserDefaults.standard.set(serverData, forKey: defaultsKey)
    }

    func load() -> (PairedServer, String)? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let server = try? JSONDecoder().decode(PairedServer.self, from: data) else { return nil }
        var request = query(server.deviceID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let secretData = item as? Data,
              let secret = String(data: secretData, encoding: .utf8) else { return nil }
        return (server, secret)
    }

    func clear() {
        if let server = load()?.0 { SecItemDelete(query(server.deviceID) as CFDictionary) }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum CredentialFailure: Error, LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            String(
                format: String(localized: "无法安全保存设备凭据（Keychain %d）。"),
                status
            )
        }
    }
}
