//
//  VehicleSkill.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/13/26.
//


import Foundation
import CoreLocation

// MARK: - Vehicle Identification Skill
class VehicleSkill: LookoutSkill {
    let category: SkillCategory = .vehicle
    let displayName: String = "Vehicle ID"
    var requiredAPIKey: String? = nil
    
    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let parsed = parseVehicleQuery(query)
        
        if let specs = try? await lookupVehicle(make: parsed.make, model: parsed.model, year: parsed.year) {
            return specs
        }
        
        return createDescriptionResult(query: query, parsed: parsed)
    }
    
    // MARK: - Parse AI Query
    
    private struct ParsedVehicle {
        var make: String = ""
        var model: String = ""
        var year: String = ""
        var color: String = ""
        var bodyType: String = ""
    }
    
    private func parseVehicleQuery(_ query: String) -> ParsedVehicle {
        var parsed = ParsedVehicle()
        let lower = query.lowercased()
        
        let makes = ["toyota", "honda", "ford", "chevrolet", "chevy", "bmw", "mercedes", "audi",
                     "tesla", "nissan", "hyundai", "kia", "subaru", "volkswagen", "vw", "jeep",
                     "ram", "gmc", "dodge", "lexus", "mazda", "acura", "infiniti", "volvo",
                     "porsche", "land rover", "jaguar", "buick", "cadillac", "lincoln",
                     "chrysler", "mitsubishi", "mini", "fiat", "alfa romeo", "genesis",
                     "rivian", "lucid", "polestar"]
        
        for make in makes {
            if lower.contains(make) {
                parsed.make = make == "chevy" ? "Chevrolet" : make == "vw" ? "Volkswagen" : make.capitalized
                break
            }
        }
        
        let colors = ["red", "blue", "black", "white", "silver", "gray", "grey", "green",
                      "yellow", "orange", "brown", "beige", "gold", "bronze", "burgundy", "maroon"]
        for color in colors {
            if lower.contains(color) {
                parsed.color = color.capitalized
                break
            }
        }
        
        let yearPattern = try? NSRegularExpression(pattern: "(19[5-9]\\d|20[0-3]\\d)")
        if let match = yearPattern?.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range, in: query) {
            parsed.year = String(query[range])
        }
        
        let bodies = ["sedan", "suv", "truck", "pickup", "coupe", "convertible", "hatchback",
                      "wagon", "van", "minivan", "crossover", "sports car", "roadster"]
        for body in bodies {
            if lower.contains(body) {
                parsed.bodyType = body.capitalized
                break
            }
        }
        
        if !parsed.make.isEmpty {
            let makeIndex = lower.range(of: parsed.make.lowercased())
            if let idx = makeIndex?.upperBound {
                let afterMake = String(query[idx...]).trimmingCharacters(in: .whitespaces)
                let words = afterMake.components(separatedBy: .whitespaces)
                parsed.model = words.prefix(2).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            }
        }
        
        return parsed
    }
    
    // MARK: - NHTSA vPIC API (Free, no key required)
    
    private func lookupVehicle(make: String, model: String, year: String) async throws -> SkillResult? {
        guard !make.isEmpty else { return nil }
        
        let encodedMake = make.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? make
        
        var urlString: String
        if !model.isEmpty && !year.isEmpty {
            urlString = "https://vpic.nhtsa.dot.gov/api/vehicles/getmodelsformakeyear/make/\(encodedMake)/modelyear/\(year)?format=json"
        } else {
            urlString = "https://vpic.nhtsa.dot.gov/api/vehicles/getmodelsformake/\(encodedMake)?format=json"
        }
        
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        let nhtsa = try JSONDecoder().decode(NHTSAResponse.self, from: data)
        
        var matchedModel: NHTSAModel?
        if !model.isEmpty {
            matchedModel = nhtsa.Results?.first(where: {
                ($0.Model_Name ?? "").lowercased().contains(model.lowercased())
            })
        }
        
        let bestModel = matchedModel ?? nhtsa.Results?.first
        
        guard let result = bestModel else { return nil }
        
        var details: [SkillResult.DetailItem] = []
        
        if let makeName = result.Make_Name {
            details.append(.init(label: "Make", value: makeName, iconName: "car"))
        }
        if let modelName = result.Model_Name {
            details.append(.init(label: "Model", value: modelName, iconName: "textformat"))
        }
        if !year.isEmpty {
            details.append(.init(label: "Year", value: year, iconName: "calendar"))
        }
        if let vehicleType = result.VehicleTypeName {
            details.append(.init(label: "Type", value: vehicleType, iconName: "car.2"))
        }
        
        let title = [year, result.Make_Name ?? make, result.Model_Name ?? model]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        return SkillResult(
            category: .vehicle,
            title: title,
            subtitle: result.VehicleTypeName ?? "Vehicle",
            details: details,
            sourceApp: "NHTSA",
            deepLinkURL: nil
        )
    }
    
    // MARK: - Fallback
    
    private func createDescriptionResult(query: String, parsed: ParsedVehicle) -> SkillResult {
        var details: [SkillResult.DetailItem] = []
        
        if !parsed.make.isEmpty {
            details.append(.init(label: "Make", value: parsed.make, iconName: "car"))
        }
        if !parsed.model.isEmpty {
            details.append(.init(label: "Model", value: parsed.model, iconName: "textformat"))
        }
        if !parsed.year.isEmpty {
            details.append(.init(label: "Year", value: parsed.year, iconName: "calendar"))
        }
        if !parsed.color.isEmpty {
            details.append(.init(label: "Color", value: parsed.color, iconName: "paintpalette"))
        }
        if !parsed.bodyType.isEmpty {
            details.append(.init(label: "Type", value: parsed.bodyType, iconName: "car.2"))
        }
        
        if details.isEmpty {
            details.append(.init(label: "Description", value: query, iconName: "car"))
        }
        
        let title = [parsed.year, parsed.make, parsed.model]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        return SkillResult(
            category: .vehicle,
            title: title.isEmpty ? "Vehicle Spotted" : title,
            subtitle: [parsed.color, parsed.bodyType].filter { !$0.isEmpty }.joined(separator: " "),
            details: details,
            sourceApp: "Lookout AI",
            deepLinkURL: nil
        )
    }
}

// MARK: - NHTSA API Models

struct NHTSAResponse: Codable {
    let Results: [NHTSAModel]?
}

struct NHTSAModel: Codable {
    let Make_ID: Int?
    let Make_Name: String?
    let Model_ID: Int?
    let Model_Name: String?
    let VehicleTypeName: String?
}