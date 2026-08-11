import Foundation
import CoreLocation

// MARK: - Medication Scanner Skill
/// Identifies medications from pill bottles/boxes and looks up drug info via OpenFDA.
class MedicationSkill: LookoutSkill {
    let category: SkillCategory = .medication
    let displayName: String = "Medication Scanner"
    var requiredAPIKey: String? = nil

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        // Extract likely drug name from the AI query
        let drugName = extractDrugName(from: query)

        // Try OpenFDA first (free, no key)
        if let fdaResult = await lookupOpenFDA(drugName: drugName) {
            return fdaResult
        }

        // Fallback: return what the AI extracted
        return SkillResult(
            category: .medication,
            title: drugName.capitalized,
            subtitle: "Medication identified",
            details: [
                .init(label: "Description", value: query, iconName: "pill"),
                .init(label: "Tip", value: "Consult your pharmacist for interactions", iconName: "info.circle")
            ],
            sourceApp: "Lookout",
            deepLinkURL: nil
        )
    }

    // MARK: - OpenFDA Lookup (free, no API key)

    private func lookupOpenFDA(drugName: String) async -> SkillResult? {
        let encoded = drugName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? drugName
        let urlStr = "https://api.fda.gov/drug/label.json?search=openfda.brand_name:\"\(encoded)\"+openfda.generic_name:\"\(encoded)\"&limit=1"
        guard let url = URL(string: urlStr) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let drug = results.first else { return nil }

            let openfda = drug["openfda"] as? [String: Any]
            let brandName = (openfda?["brand_name"] as? [String])?.first ?? drugName
            let genericName = (openfda?["generic_name"] as? [String])?.first ?? ""
            let manufacturer = (openfda?["manufacturer_name"] as? [String])?.first ?? ""
            let route = (openfda?["route"] as? [String])?.first ?? ""
            let substanceName = (openfda?["substance_name"] as? [String])?.first ?? ""

            let purpose = (drug["purpose"] as? [String])?.first ?? ""
            let warnings = (drug["warnings"] as? [String])?.first?.prefix(300) ?? ""
            let dosage = (drug["dosage_and_administration"] as? [String])?.first?.prefix(300) ?? ""
            let interactions = (drug["drug_interactions"] as? [String])?.first?.prefix(300) ?? ""

            var details: [SkillResult.DetailItem] = []
            if !genericName.isEmpty {
                details.append(.init(label: "Generic Name", value: genericName, iconName: "pills"))
            }
            if !substanceName.isEmpty && substanceName != genericName {
                details.append(.init(label: "Active Ingredient", value: substanceName, iconName: "atom"))
            }
            if !manufacturer.isEmpty {
                details.append(.init(label: "Manufacturer", value: manufacturer, iconName: "building.2"))
            }
            if !route.isEmpty {
                details.append(.init(label: "Route", value: route.capitalized, iconName: "arrow.right.circle"))
            }
            if !purpose.isEmpty {
                details.append(.init(label: "Purpose", value: String(purpose.prefix(200)), iconName: "cross.case"))
            }
            if !dosage.isEmpty {
                details.append(.init(label: "Dosage", value: String(dosage), iconName: "clock"))
            }
            if !warnings.isEmpty {
                details.append(.init(label: "Warnings", value: String(warnings), iconName: "exclamationmark.triangle"))
            }
            if !interactions.isEmpty {
                details.append(.init(label: "Interactions", value: String(interactions), iconName: "arrow.triangle.merge"))
            }

            return SkillResult(
                category: .medication,
                title: brandName,
                subtitle: genericName.isEmpty ? "Medication" : genericName,
                details: details,
                sourceApp: "OpenFDA",
                deepLinkURL: nil
            )
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func extractDrugName(from query: String) -> String {
        // Clean up the AI query to get just the drug name
        var name = query
            .replacingOccurrences(of: "\\d+\\s*(mg|mcg|ml|g)\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "tablet|capsule|pill|bottle|box|prescription|label", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Take the first meaningful word(s)
        let words = name.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 }
        name = words.prefix(3).joined(separator: " ")
        return name.isEmpty ? query : name
    }
}
