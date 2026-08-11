import Foundation
import CoreLocation
import Vision
import UIKit

// MARK: - QR Code Skill
/// Handles QR codes differently from standard barcodes.
/// Detects and processes URLs, WiFi credentials, contact cards, calendar events, etc.
class QRCodeSkill: LookoutSkill {
    let category: SkillCategory = .qrCode
    let displayName: String = "QR Code Reader"
    var requiredAPIKey: String? = nil

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let payload = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let qrType = classifyQRPayload(payload)

        switch qrType {
        case .url(let url):
            return SkillResult(
                category: .qrCode,
                title: "Web Link",
                subtitle: url.host ?? payload,
                details: [
                    .init(label: "URL", value: payload, iconName: "link"),
                    .init(label: "Action", value: "Tap to open in Safari", iconName: "safari")
                ],
                sourceApp: "QR Code",
                deepLinkURL: url
            )

        case .wifi(let ssid, let password, let security):
            var details: [SkillResult.DetailItem] = [
                .init(label: "Network", value: ssid, iconName: "wifi"),
            ]
            if !password.isEmpty {
                details.append(.init(label: "Password", value: password, iconName: "lock"))
            }
            if !security.isEmpty {
                details.append(.init(label: "Security", value: security, iconName: "shield"))
            }
            return SkillResult(
                category: .qrCode,
                title: "WiFi: \(ssid)",
                subtitle: "Network credentials",
                details: details,
                sourceApp: "QR Code",
                deepLinkURL: nil
            )

        case .vcard(let name, let fields):
            var details: [SkillResult.DetailItem] = []
            for (key, value) in fields {
                let icon: String
                switch key.lowercased() {
                case "tel": icon = "phone"
                case "email": icon = "envelope"
                case "org": icon = "building.2"
                case "title": icon = "briefcase"
                case "url": icon = "globe"
                default: icon = "info.circle"
                }
                details.append(.init(label: key, value: value, iconName: icon))
            }
            return SkillResult(
                category: .qrCode,
                title: name,
                subtitle: "Contact Card",
                details: details,
                sourceApp: "QR Code",
                deepLinkURL: nil
            )

        case .text:
            return SkillResult(
                category: .qrCode,
                title: "QR Code Content",
                subtitle: String(payload.prefix(80)),
                details: [
                    .init(label: "Content", value: payload, iconName: "text.alignleft"),
                    .init(label: "Length", value: "\(payload.count) characters", iconName: "number")
                ],
                sourceApp: "QR Code",
                deepLinkURL: nil
            )
        }
    }

    // MARK: - QR Payload Classification

    private enum QRType {
        case url(URL)
        case wifi(ssid: String, password: String, security: String)
        case vcard(name: String, fields: [(String, String)])
        case text
    }

    private func classifyQRPayload(_ payload: String) -> QRType {
        // URL
        if let url = URL(string: payload), url.scheme != nil,
           (payload.lowercased().hasPrefix("http") || payload.lowercased().hasPrefix("https")) {
            return .url(url)
        }

        // WiFi: WIFI:T:WPA;S:NetworkName;P:Password;;
        if payload.uppercased().hasPrefix("WIFI:") {
            let ssid = extractWifiField(payload, field: "S") ?? ""
            let password = extractWifiField(payload, field: "P") ?? ""
            let security = extractWifiField(payload, field: "T") ?? ""
            return .wifi(ssid: ssid, password: password, security: security)
        }

        // vCard
        if payload.uppercased().contains("BEGIN:VCARD") {
            let (name, fields) = parseVCard(payload)
            return .vcard(name: name, fields: fields)
        }

        // Deep link URLs (app-specific schemes)
        if let url = URL(string: payload), url.scheme != nil {
            return .url(url)
        }

        return .text
    }

    private func extractWifiField(_ payload: String, field: String) -> String? {
        let pattern = "\(field):([^;]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: payload, range: NSRange(payload.startIndex..., in: payload)),
              let range = Range(match.range(at: 1), in: payload) else { return nil }
        return String(payload[range])
    }

    private func parseVCard(_ raw: String) -> (name: String, fields: [(String, String)]) {
        var name = "Contact"
        var fields: [(String, String)] = []

        for line in raw.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).uppercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            if key.contains("FN") {
                name = value
            } else if key.contains("TEL") {
                fields.append(("Tel", value))
            } else if key.contains("EMAIL") {
                fields.append(("Email", value))
            } else if key.contains("ORG") {
                fields.append(("Org", value))
            } else if key.contains("TITLE") {
                fields.append(("Title", value))
            } else if key.contains("URL") {
                fields.append(("URL", value))
            }
        }

        return (name, fields)
    }
}
