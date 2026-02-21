import Foundation
import CoreLocation

// MARK: - Skill Category
enum SkillCategory: String, Codable, CaseIterable {
    case flight = "flight"
    case landmark = "landmark"
    case music = "music"
    case plant = "plant"
    case vehicle = "vehicle"
    case product = "product"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .flight: return "Flight Tracking"
        case .landmark: return "Landmark / Building"
        case .music: return "Music Identification"
        case .plant: return "Nature ID"
        case .vehicle: return "Vehicle"
        case .product: return "Product / Barcode"
        case .unknown: return "General"
        }
    }
    
    var badgeName: String {
        switch self {
        case .flight: return "FLIGHT"
        case .landmark: return "LANDMARK"
        case .music: return "MUSIC"
        case .plant: return "NATURE"
        case .vehicle: return "VEHICLE"
        case .product: return "PRODUCT"
        case .unknown: return "UNKNOWN"
        }
    }
    
    var iconName: String {
        switch self {
        case .flight: return "airplane"
        case .landmark: return "building.2"
        case .music: return "music.note"
        case .plant: return "leaf"
        case .vehicle: return "car"
        case .product: return "barcode"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - AI Vision Response
struct AIVisionResponse: Codable {
    let category: String
    let description: String
    let query: String // What to search for in the skill
    let confidence: Double
    
    var skillCategory: SkillCategory {
        SkillCategory(rawValue: category) ?? .unknown
    }
}

// MARK: - Skill Result
struct SkillResult: Identifiable {
    let id = UUID()
    let category: SkillCategory
    let title: String
    let subtitle: String
    let details: [DetailItem]
    let sourceApp: String
    let deepLinkURL: URL?
    let timestamp: Date = Date()
    
    struct DetailItem: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let iconName: String?
    }
}

// MARK: - Skill Protocol
protocol LookoutSkill {
    var category: SkillCategory { get }
    var displayName: String { get }
    var requiredAPIKey: String? { get }
    
    func execute(query: String, location: CLLocation?) async throws -> SkillResult
}

// MARK: - Lookout Query
struct LookoutQuery: Identifiable {
    let id = UUID()
    let imageData: Data?
    let timestamp: Date = Date()
    var aiResponse: AIVisionResponse?
    var skillResult: SkillResult?
    var status: QueryStatus = .analyzing
    var errorMessage: String?
    
    enum QueryStatus: Equatable {
        case analyzing
        case routing
        case executingFlight
        case executingLandmark
        case executingMusic
        case executingPlant
        case executingVehicle
        case executingProduct
        case executingGeneral
        case complete
        case error

        var displayText: String {
            switch self {
            case .analyzing:        return "Asking AI to identify..."
            case .routing:          return "Choosing the right tool..."
            case .executingFlight:  return "Looking up flight data..."
            case .executingLandmark:return "Looking up landmark info..."
            case .executingMusic:   return "Listening for music (5s)..."
            case .executingPlant:   return "Identifying species..."
            case .executingVehicle: return "Looking up vehicle..."
            case .executingProduct: return "Looking up product..."
            case .executingGeneral: return "Fetching details..."
            case .complete:         return "Done"
            case .error:            return "Error"
            }
        }

        // Legacy rawValue shim so existing Text(query.status.rawValue) callers still compile
        var rawValue: String { displayText }
    }
}
