//
//  PlantSkill.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/13/26.
//


import Foundation
import CoreLocation

// MARK: - Plant & Animal Identification Skill
class PlantSkill: LookoutSkill {
    let category: SkillCategory = .plant
    let displayName: String = "Nature ID"
    var requiredAPIKey: String? = nil
    
    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let results = try await searchiNaturalist(query: query)
        
        if let best = results.first {
            var details: [SkillResult.DetailItem] = []
            let natureType = classifyNatureType(iconicTaxon: best.iconicTaxonName)
            let typeIcon = natureType == "Animal" ? "pawprint.fill" : "leaf.fill"
            
            details.append(.init(label: "Type", value: natureType, iconName: typeIcon))
            
            details.append(.init(label: "Common Name", value: best.commonName, iconName: "leaf"))
            details.append(.init(label: "Scientific Name", value: best.scientificName, iconName: "text.book.closed"))
            
            if !best.rank.isEmpty {
                details.append(.init(label: "Rank", value: best.rank.capitalized, iconName: "chart.bar"))
            }
            
            if let obsCount = best.observationsCount {
                details.append(.init(label: "Observations", value: "\(obsCount.formatted()) worldwide", iconName: "globe"))
            }
            
            if best.isEndangered {
                details.append(.init(label: "Conservation", value: best.conservationStatus ?? "Threatened", iconName: "exclamationmark.triangle"))
            }
            
            if !best.wikipediaSummary.isEmpty {
                details.append(.init(label: "Summary", value: best.wikipediaSummary, iconName: "doc.text"))
            }
            
            let iNatURL = URL(string: "https://www.inaturalist.org/taxa/\(best.id)")
            let subtitle = natureType == "Animal"
                ? "\(best.scientificName) - Animal"
                : best.scientificName
            
            return SkillResult(
                category: .plant,
                title: best.commonName,
                subtitle: subtitle,
                details: details,
                sourceApp: "iNaturalist",
                deepLinkURL: iNatURL
            )
        }
        
        return createFallbackResult(query: query)
    }
    
    // MARK: - iNaturalist API
    
    private func searchiNaturalist(query: String) async throws -> [INaturalistTaxon] {
        let cleanQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://api.inaturalist.org/v1/taxa?q=\(cleanQuery)&per_page=3&locale=en"
        
        guard let url = URL(string: urlString) else {
            throw LookoutError.networkError("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LookoutError.apiError("iNaturalist API error")
        }
        
        let iNatResponse = try JSONDecoder().decode(INaturalistResponse.self, from: data)
        
        return iNatResponse.results.map { result in
            INaturalistTaxon(
                id: result.id,
                commonName: result.preferred_common_name ?? result.name,
                scientificName: result.name,
                rank: result.rank ?? "",
                observationsCount: result.observations_count,
                isEndangered: result.conservation_status != nil,
                conservationStatus: result.conservation_status?.status_name,
                wikipediaSummary: cleanWikipedia(result.wikipedia_summary),
                photoURL: result.default_photo?.medium_url,
                iconicTaxonName: result.iconic_taxon_name
            )
        }
    }
    
    private func cleanWikipedia(_ html: String?) -> String {
        guard let html = html else { return "" }
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let sentences = stripped.components(separatedBy: ". ")
        let trimmed = sentences.prefix(2).joined(separator: ". ")
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
    
    private func classifyNatureType(iconicTaxon: String?) -> String {
        guard let iconic = iconicTaxon?.lowercased() else { return "Species" }
        
        let animalTaxa: Set<String> = [
            "animalia", "mammalia", "aves", "reptilia", "amphibia", "actinopterygii",
            "insecta", "arachnida", "mollusca"
        ]
        if animalTaxa.contains(iconic) { return "Animal" }
        if iconic == "plantae" { return "Plant" }
        if iconic == "fungi" { return "Fungus" }
        return "Species"
    }
    
    private func createFallbackResult(query: String) -> SkillResult {
        SkillResult(
            category: .plant,
            title: "Nature Spotted",
            subtitle: query,
            details: [
                .init(label: "Description", value: query, iconName: "leaf"),
                .init(label: "Tip", value: "Try getting a closer photo showing key features like leaves, petals, or markings.", iconName: "camera")
            ],
            sourceApp: "Lookout",
            deepLinkURL: nil
        )
    }
}

// MARK: - iNaturalist API Models

struct INaturalistResponse: Codable {
    let results: [INaturalistResult]
}

struct INaturalistResult: Codable {
    let id: Int
    let name: String
    let preferred_common_name: String?
    let rank: String?
    let observations_count: Int?
    let wikipedia_summary: String?
    let conservation_status: INaturalistConservation?
    let default_photo: INaturalistPhoto?
    let iconic_taxon_name: String?
}

struct INaturalistConservation: Codable {
    let status_name: String?
}

struct INaturalistPhoto: Codable {
    let medium_url: String?
}

struct INaturalistTaxon {
    let id: Int
    let commonName: String
    let scientificName: String
    let rank: String
    let observationsCount: Int?
    let isEndangered: Bool
    let conservationStatus: String?
    let wikipediaSummary: String
    let photoURL: String?
    let iconicTaxonName: String?
}
