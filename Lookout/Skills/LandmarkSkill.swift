import Foundation
import CoreLocation

// MARK: - Landmark Skill
class LandmarkSkill: LookoutSkill {
    let category: SkillCategory = .landmark
    let displayName: String = "Landmark Identifier"
    var requiredAPIKey: String?
    
    private let googlePlacesAPIKey: String
    
    init(googlePlacesAPIKey: String = "") {
        self.googlePlacesAPIKey = googlePlacesAPIKey
    }
    
    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        // If we have a Google Places API key and location, use Places API
        if !googlePlacesAPIKey.isEmpty, let location = location {
            return try await searchGooglePlaces(query: query, location: location)
        }
        
        // Fallback: use Wikipedia API (free, no key needed)
        return try await searchWikipedia(query: query)
    }
    
    // MARK: - Google Places Nearby Search
    private func searchGooglePlaces(query: String, location: CLLocation) async throws -> SkillResult {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=\(lat),\(lon)&radius=500&keyword=\(encodedQuery)&key=\(googlePlacesAPIKey)"
        
        guard let url = URL(string: urlString) else {
            throw LookoutError.networkError("Invalid URL")
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let placesResponse = try JSONDecoder().decode(GooglePlacesResponse.self, from: data)
        
        if let place = placesResponse.results.first {
            var details: [SkillResult.DetailItem] = []
            
            details.append(.init(label: "Address", value: place.vicinity ?? "Unknown", iconName: "mappin"))
            
            if let rating = place.rating {
                details.append(.init(label: "Rating", value: "\(rating) ⭐ (\(place.userRatingsTotal ?? 0) reviews)", iconName: "star"))
            }
            
            if let types = place.types?.prefix(3) {
                let typeStr = types.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: ", ")
                details.append(.init(label: "Type", value: typeStr, iconName: "tag"))
            }
            
            if let openNow = place.openingHours?.openNow {
                details.append(.init(label: "Status", value: openNow ? "Open Now" : "Closed", iconName: "clock"))
            }
            
            // Deep link to Apple Maps
            let mapsURL = URL(string: "maps://?q=\(encodedQuery)&ll=\(place.geometry?.location.lat ?? lat),\(place.geometry?.location.lng ?? lon)")
            
            return SkillResult(
                category: .landmark,
                title: place.name,
                subtitle: place.vicinity ?? query,
                details: details,
                sourceApp: "Google Places",
                deepLinkURL: mapsURL
            )
        }
        
        // Fallback to Wikipedia if no places found
        return try await searchWikipedia(query: query)
    }
    
    // MARK: - Wikipedia Search (Free fallback)
    private func searchWikipedia(query: String) async throws -> SkillResult {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://en.wikipedia.org/api/rest_v1/page/summary/\(encodedQuery)"
        
        guard let url = URL(string: urlString) else {
            // Try search API instead
            return try await searchWikipediaFull(query: query)
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            let wikiResponse = try JSONDecoder().decode(WikipediaSummary.self, from: data)
            
            var details: [SkillResult.DetailItem] = []
            details.append(.init(label: "Summary", value: wikiResponse.extract ?? "No summary available", iconName: "doc.text"))
            
            if let coords = wikiResponse.coordinates {
                details.append(.init(label: "Location", value: "\(coords.lat), \(coords.lon)", iconName: "mappin"))
            }
            
            let wikiURL = URL(string: wikiResponse.contentUrls?.mobile?.page ?? "https://en.wikipedia.org")
            
            return SkillResult(
                category: .landmark,
                title: wikiResponse.title,
                subtitle: wikiResponse.description ?? query,
                details: details,
                sourceApp: "Wikipedia",
                deepLinkURL: wikiURL
            )
        }
        
        return try await searchWikipediaFull(query: query)
    }
    
    // MARK: - Wikipedia Full Search
    private func searchWikipediaFull(query: String) async throws -> SkillResult {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encodedQuery)&format=json&srlimit=1"
        
        guard let url = URL(string: urlString) else {
            throw LookoutError.networkError("Invalid URL")
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let searchResponse = try JSONDecoder().decode(WikiSearchResponse.self, from: data)
        
        if let result = searchResponse.query.search.first {
            let snippet = result.snippet
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            
            return SkillResult(
                category: .landmark,
                title: result.title,
                subtitle: "Wikipedia",
                details: [
                    .init(label: "Summary", value: snippet, iconName: "doc.text")
                ],
                sourceApp: "Wikipedia",
                deepLinkURL: URL(string: "https://en.wikipedia.org/wiki/\(result.title.replacingOccurrences(of: " ", with: "_"))")
            )
        }
        
        return SkillResult(
            category: .landmark,
            title: "Landmark",
            subtitle: query,
            details: [.init(label: "Info", value: "Could not find specific information", iconName: "info.circle")],
            sourceApp: "Lookout",
            deepLinkURL: nil
        )
    }
}

// MARK: - Google Places Models
struct GooglePlacesResponse: Codable {
    let results: [PlaceResult]
    
    struct PlaceResult: Codable {
        let name: String
        let vicinity: String?
        let rating: Double?
        let userRatingsTotal: Int?
        let types: [String]?
        let geometry: Geometry?
        let openingHours: OpeningHours?
        
        enum CodingKeys: String, CodingKey {
            case name, vicinity, rating, types, geometry
            case userRatingsTotal = "user_ratings_total"
            case openingHours = "opening_hours"
        }
    }
    
    struct Geometry: Codable {
        let location: LatLng
    }
    
    struct LatLng: Codable {
        let lat: Double
        let lng: Double
    }
    
    struct OpeningHours: Codable {
        let openNow: Bool?
        enum CodingKeys: String, CodingKey {
            case openNow = "open_now"
        }
    }
}

// MARK: - Wikipedia Models
struct WikipediaSummary: Codable {
    let title: String
    let description: String?
    let extract: String?
    let coordinates: WikiCoords?
    let contentUrls: ContentUrls?
    
    enum CodingKeys: String, CodingKey {
        case title, description, extract, coordinates
        case contentUrls = "content_urls"
    }
}

struct WikiCoords: Codable {
    let lat: Double
    let lon: Double
}

struct ContentUrls: Codable {
    let mobile: URLInfo?
}

struct URLInfo: Codable {
    let page: String?
}

struct WikiSearchResponse: Codable {
    let query: WikiQuery
}

struct WikiQuery: Codable {
    let search: [WikiSearchResult]
}

struct WikiSearchResult: Codable {
    let title: String
    let snippet: String
}
