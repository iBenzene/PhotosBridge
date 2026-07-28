//
//  QRScannerView.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import SwiftUI
import Vision
import VisionKit

struct PairingQRCode: Decodable {
    let serverURL: URL
    let pairingToken: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case pairingToken = "pairing_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let urlString = try container.decode(String.self, forKey: .serverURL)
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DecodingError.dataCorruptedError(forKey: .serverURL, in: container, debugDescription: "Invalid URL")
        }
        self.serverURL = url
        self.pairingToken = try container.decode(String.self, forKey: .pairingToken).trimmingCharacters(in: .whitespacesAndNewlines)

        if let dateString = try? container.decode(String.self, forKey: .expiresAt) {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            self.expiresAt = f1.date(from: dateString) ?? f2.date(from: dateString)
        } else {
            self.expiresAt = nil
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    static var isSupported: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }
    let onResult: (PairingQRCode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let parent: QRScannerView
        init(parent: QRScannerView) { self.parent = parent }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            processItems(addedItems, scanner: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            processItems([item], scanner: dataScanner)
        }

        private func processItems(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            for item in items {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue,
                      let data = value.data(using: .utf8) else { continue }
                guard let payload = try? JSONDecoder().decode(PairingQRCode.self, from: data) else { continue }
                if let expiresAt = payload.expiresAt, expiresAt <= Date() {
                    continue
                }
                scanner.stopScanning()
                parent.onResult(payload)
                return
            }
        }
    }
}
