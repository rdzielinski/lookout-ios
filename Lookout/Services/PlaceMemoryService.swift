import Foundation
import CoreLocation

// MARK: - Place Memory Service
/// Saves and recognizes familiar places by GPS coordinates.
/// Checks nearby saved places before querying external APIs.
class PlaceMemoryService: ObservableObject {
    
    @Published var savedPlaces: [SavedPlace] = []
    
    private let storageURL: URL
    private let defaultRadius: Double = 100 // meters
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("lookout_places.json")
        loadPlaces()
    }
    
    // MARK: - Check Nearby
    
    /// Check if the user is near a saved place.
    func findNearbyPlace(location: CLLocation) -> SavedPlace? {
        for place in savedPlaces {
            let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let distance = location.distance(from: placeLocation)
            
            if distance <= place.radius {
                return place
            }
        }
        return nil
    }
    
    /// Get all places within a given radius of a location.
    func findPlacesNear(location: CLLocation, radius: Double = 500) -> [SavedPlace] {
        savedPlaces.filter { place in
            let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            return location.distance(from: placeLocation) <= radius
        }
    }
    
    // MARK: - Save Place
    
    func savePlace(name: String, location: CLLocation, category: PlaceCategory = .other, notes: String = "", radius: Double? = nil) {
        // Check for duplicates
        if let idx = savedPlaces.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            // Update existing
            savedPlaces[idx].latitude = location.coordinate.latitude
            savedPlaces[idx].longitude = location.coordinate.longitude
            savedPlaces[idx].lastVisited = Date()
            savedPlaces[idx].visitCount += 1
            if !notes.isEmpty { savedPlaces[idx].notes = notes }
        } else {
            let place = SavedPlace(
                name: name,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                radius: radius ?? defaultRadius,
                category: category,
                notes: notes,
                createdAt: Date(),
                lastVisited: Date(),
                visitCount: 1
            )
            savedPlaces.append(place)
        }
        
        savePlacesToDisk()
    }
    
    /// Quick save from current location
    func saveCurrentLocation(name: String, location: CLLocation, category: PlaceCategory = .other) {
        savePlace(name: name, location: location, category: category)
    }
    
    /// Mark a place as visited (increment counter)
    func markVisited(name: String) {
        if let idx = savedPlaces.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            savedPlaces[idx].lastVisited = Date()
            savedPlaces[idx].visitCount += 1
            savePlacesToDisk()
        }
    }
    
    /// Remove a saved place
    func removePlace(id: UUID) {
        savedPlaces.removeAll { $0.id == id }
        savePlacesToDisk()
    }
    
    /// Remove all places
    func removeAllPlaces() {
        savedPlaces = []
        savePlacesToDisk()
    }

    // MARK: - Parking Spot

    /// Save current location as a parking spot. Auto-expires after 24 hours.
    func saveParkingSpot(location: CLLocation, notes: String = "") {
        // Remove any existing parking spot
        savedPlaces.removeAll { $0.category == .parking }

        let spot = SavedPlace(
            name: "My Parked Car",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radius: 50,
            category: .parking,
            notes: notes.isEmpty ? "Saved \(formattedNow)" : notes
        )
        savedPlaces.append(spot)
        savePlacesToDisk()
    }

    /// Get the current parking spot if it exists and hasn't expired (24h).
    func currentParkingSpot() -> SavedPlace? {
        guard let spot = savedPlaces.first(where: { $0.category == .parking }) else { return nil }
        // Auto-expire after 24 hours
        if Date().timeIntervalSince(spot.createdAt) > 86400 {
            savedPlaces.removeAll { $0.category == .parking }
            savePlacesToDisk()
            return nil
        }
        return spot
    }

    /// Clear parking spot
    func clearParkingSpot() {
        savedPlaces.removeAll { $0.category == .parking }
        savePlacesToDisk()
    }

    private var formattedNow: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date())
    }
    
    // MARK: - Persistence
    
    private func loadPlaces() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            savedPlaces = try JSONDecoder().decode([SavedPlace].self, from: data)
        } catch {
            #if DEBUG
            print("⚠️ Failed to load places: \(error)")
            #endif
        }
    }
    
    private func savePlacesToDisk() {
        do {
            let data = try JSONEncoder().encode(savedPlaces)
            try data.write(to: storageURL)
        } catch {
            #if DEBUG
            print("⚠️ Failed to save places: \(error)")
            #endif
        }
    }
    
    // MARK: - Context for AI
    
    var contextSummary: String {
        guard !savedPlaces.isEmpty else { return "" }
        let places = savedPlaces.prefix(10).map { place in
            "\(place.name) (\(place.category.rawValue))"
        }
        return "Saved places: \(places.joined(separator: ", "))"
    }
    
    func nearbyContextSummary(location: CLLocation?) -> String {
        guard let location = location else { return "" }
        
        if let nearby = findNearbyPlace(location: location) {
            return "Currently at or near: \(nearby.name)"
        }
        
        let nearish = findPlacesNear(location: location, radius: 1000)
        if !nearish.isEmpty {
            let names = nearish.prefix(3).map { $0.name }
            return "Near: \(names.joined(separator: ", "))"
        }
        
        return ""
    }
}

// MARK: - Models

enum PlaceCategory: String, Codable, CaseIterable {
    case home = "Home"
    case work = "Work"
    case school = "School"
    case restaurant = "Restaurant"
    case store = "Store"
    case park = "Park"
    case gym = "Gym"
    case friend = "Friend's Place"
    case family = "Family"
    case parking = "Parking"
    case other = "Other"

    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case .school: return "graduationcap.fill"
        case .restaurant: return "fork.knife"
        case .store: return "bag.fill"
        case .park: return "leaf.fill"
        case .gym: return "figure.run"
        case .friend: return "person.fill"
        case .family: return "person.2.fill"
        case .parking: return "car.fill"
        case .other: return "mappin"
        }
    }
}

struct SavedPlace: Codable, Identifiable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var category: PlaceCategory
    var notes: String
    var createdAt: Date
    var lastVisited: Date
    var visitCount: Int
    
    init(name: String, latitude: Double, longitude: Double, radius: Double = 100, category: PlaceCategory = .other, notes: String = "", createdAt: Date = Date(), lastVisited: Date = Date(), visitCount: Int = 1) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.category = category
        self.notes = notes
        self.createdAt = createdAt
        self.lastVisited = lastVisited
        self.visitCount = visitCount
    }
}
