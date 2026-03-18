import Foundation
import CoreLocation

// MARK: - User Context Store
/// A persistent local "brain" that accumulates knowledge about the user over time.
/// Learns products, pets, preferences, and patterns from scan history.
class UserContextStore: ObservableObject {
    
    @Published var context: UserContext
    
    private let storageURL: URL
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        storageURL = docs.appendingPathComponent("lookout_context.json")
        context = UserContext()
        loadContext()
    }
    
    // MARK: - Record Scan Events
    
    func recordScan(category: String, query: String, title: String, details: [String: String] = [:]) {
        context.totalScans += 1
        context.categoryCounts[category, default: 0] += 1
        context.lastScanDate = Date()
        
        // Track recent items (last 50 for richer history)
        let item = ScanHistoryItem(
            category: category,
            title: title,
            query: query,
            date: Date(),
            details: details
        )
        context.recentScans.insert(item, at: 0)
        if context.recentScans.count > 50 {
            context.recentScans = Array(context.recentScans.prefix(50))
        }
        
        // Auto-learn from product scans
        if category == "product" {
            learnProduct(title: title, details: details)
        }
        
        saveContext()
    }
    
    // MARK: - Product Memory
    
    /// Learn from repeated product scans — tracks frequency, sizes, brand preferences
    private func learnProduct(title: String, details: [String: String]) {
        let key = normalizeProductKey(title)
        
        if var product = context.knownProducts[key] {
            product.scanCount += 1
            product.lastSeen = Date()
            
            // Learn size preference if present
            if let size = details["Size"] ?? details["Quantity"] {
                product.sizesSeen[size, default: 0] += 1
            }
            if let brand = details["Brand"], !brand.isEmpty {
                product.brand = brand
            }
            
            context.knownProducts[key] = product
        } else {
            context.knownProducts[key] = ProductMemory(
                name: title,
                brand: details["Brand"] ?? "",
                scanCount: 1,
                firstSeen: Date(),
                lastSeen: Date(),
                sizesSeen: {
                    if let size = details["Size"] ?? details["Quantity"] {
                        return [size: 1]
                    }
                    return [:]
                }(),
                category: details["Category"] ?? ""
            )
        }
    }
    
    /// Get memory for a product (for AI context)
    func productMemory(for title: String) -> ProductMemory? {
        let key = normalizeProductKey(title)
        return context.knownProducts[key]
    }
    
    /// Preferred size for a product (most frequently scanned size)
    func preferredSize(for title: String) -> String? {
        guard let product = productMemory(for: title) else { return nil }
        return product.sizesSeen.max(by: { $0.value < $1.value })?.key
    }
    
    /// Count matching titles in scan history using normalized title matching.
    /// Optionally constrains by category.
    func repeatCount(forTitle title: String, category: String? = nil) -> Int {
        let lookup = normalizeScanTitle(title)
        guard !lookup.isEmpty else { return 0 }
        
        return context.recentScans.filter { scan in
            let titleMatch = normalizeScanTitle(scan.title) == lookup
            let categoryMatch = category.map { scan.category == $0 } ?? true
            return titleMatch && categoryMatch
        }.count
    }
    
    /// Backward-compatible alias used elsewhere in the app.
    func recentScanCount(forTitle title: String) -> Int {
        repeatCount(forTitle: title)
    }
    
    private func normalizeScanTitle(_ title: String) -> String {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
        return cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func normalizeProductKey(_ title: String) -> String {
        // Normalize: lowercase, remove size info, trim
        var key = title.lowercased()
        // Remove common size patterns
        let sizePatterns = ["\\d+\\s*oz", "\\d+\\s*ml", "\\d+\\s*l\\b", "\\d+\\s*fl oz", "\\d+\\s*pack", "\\d+\\s*ct"]
        for pattern in sizePatterns {
            key = key.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Pet / Object Memory
    
    /// Save a named pet or object with a visual description from the AI
    func savePet(name: String, species: String, description: String, relationship: String = "") {
        let pet = PetMemory(
            name: name,
            species: species,
            visualDescription: description,
            relationship: relationship,
            firstSeen: Date(),
            lastSeen: Date(),
            timesSeen: 1
        )
        context.knownPets[name.lowercased()] = pet
        saveContext()
    }
    
    /// Update a pet sighting
    func recordPetSighting(name: String) {
        let key = name.lowercased()
        if var pet = context.knownPets[key] {
            pet.timesSeen += 1
            pet.lastSeen = Date()
            context.knownPets[key] = pet
            saveContext()
        }
    }
    
    /// Try to match a visual description to a known pet
    /// Returns the pet name if the AI description closely matches a stored pet
    func matchPet(species: String, description: String) -> PetMemory? {
        let lowerDesc = description.lowercased()
        let lowerSpecies = species.lowercased()
        
        for (_, pet) in context.knownPets {
            // Species must match
            guard pet.species.lowercased() == lowerSpecies ||
                  lowerSpecies.contains(pet.species.lowercased()) ||
                  pet.species.lowercased().contains(lowerSpecies) else { continue }
            
            // Check visual description overlap (keywords)
            let petKeywords = extractKeywords(from: pet.visualDescription)
            let descKeywords = extractKeywords(from: lowerDesc)
            
            let overlap = petKeywords.intersection(descKeywords)
            let matchScore = Double(overlap.count) / max(Double(petKeywords.count), 1)
            
            // 40% keyword overlap = likely same animal
            if matchScore >= 0.4 || overlap.count >= 3 {
                return pet
            }
        }
        
        return nil
    }
    
    /// Get all known pets
    var knownPets: [PetMemory] {
        Array(context.knownPets.values).sorted { $0.timesSeen > $1.timesSeen }
    }
    
    /// Remove a pet
    func removePet(name: String) {
        context.knownPets.removeValue(forKey: name.lowercased())
        saveContext()
    }
    
    private func extractKeywords(from text: String) -> Set<String> {
        let stopWords: Set<String> = ["a", "an", "the", "is", "it", "its", "has", "have", "with",
                                       "and", "or", "but", "in", "on", "at", "to", "for", "of",
                                       "this", "that", "very", "quite", "rather", "some", "any",
                                       "appears", "looks", "seems", "like", "being", "about"]
        
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        
        return Set(words)
    }
    
    // MARK: - Face Recognition
    
    func recordFaceRecognition(name: String) {
        context.peopleSeen[name, default: 0] += 1
        saveContext()
    }
    
    // MARK: - Place Visits
    
    func recordPlaceVisit(name: String) {
        context.placesVisited[name, default: 0] += 1
        saveContext()
    }
    
    // MARK: - Preferences
    
    func setPreference(key: String, value: String) {
        context.preferences[key] = value
        saveContext()
    }
    
    func getPreference(key: String) -> String? {
        return context.preferences[key]
    }
    
    // MARK: - Build AI Context String
    
    func buildContextPrompt(
        personalContext: String = "",
        faceContext: String = "",
        placeContext: String = "",
        nearbyContext: String = "",
        currentScanTitle: String = "",
        currentScanCategory: String = ""
    ) -> String {
        var parts: [String] = []
        
        // Personal context (user-provided "about me")
        if !personalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("About the user: \(personalContext.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        
        // Product knowledge — things the user buys/scans regularly
        let frequentProducts = context.knownProducts.values
            .filter { $0.scanCount >= 2 }
            .sorted { $0.scanCount > $1.scanCount }
            .prefix(5)
        
        if !frequentProducts.isEmpty {
            var productLines: [String] = []
            for product in frequentProducts {
                var line = "\(product.name)"
                if !product.brand.isEmpty { line = "\(product.brand) \(line)" }
                line += " (scanned \(product.scanCount)×)"
                
                if let preferredSize = product.sizesSeen.max(by: { $0.value < $1.value })?.key {
                    line += ", usually \(preferredSize)"
                }
                productLines.append(line)
            }
            parts.append("Frequently scanned products: \(productLines.joined(separator: "; ")).")
        }
        
        // Pet knowledge
        if !context.knownPets.isEmpty {
            let petDescriptions = context.knownPets.values.map { pet in
                var desc = "\(pet.name) (\(pet.species))"
                if !pet.relationship.isEmpty { desc += " — \(pet.relationship)" }
                return desc
            }
            parts.append("Known pets/animals: \(petDescriptions.joined(separator: ", ")).")
        }
        
        // Usage patterns
        if context.totalScans > 0 {
            let topCategories = context.categoryCounts
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key) (\($0.value) times)" }
            
            if !topCategories.isEmpty {
                parts.append("Scan patterns: \(topCategories.joined(separator: ", ")) out of \(context.totalScans) total.")
            }
        }
        
        // Recent activity
        if let lastScan = context.recentScans.first {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let timeAgo = formatter.localizedString(for: lastScan.date, relativeTo: Date())
            parts.append("Last scanned: \(lastScan.title) (\(lastScan.category)) \(timeAgo).")
        }
        
        // Current scan evidence (strict anti-hallucination signal)
        if !currentScanTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let repeatCount = repeatCount(
                forTitle: currentScanTitle,
                category: currentScanCategory.isEmpty ? nil : currentScanCategory
            )
            parts.append("Current scan evidence: title=\"\(currentScanTitle)\", category=\"\(currentScanCategory)\", repeat_count=\(repeatCount).")
        }
        
        // People context
        if !faceContext.isEmpty { parts.append(faceContext) }
        
        if !context.peopleSeen.isEmpty {
            let frequentPeople = context.peopleSeen
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { $0.key }
            parts.append("Frequently seen people: \(frequentPeople.joined(separator: ", ")).")
        }
        
        // Place context
        if !nearbyContext.isEmpty { parts.append(nearbyContext) }
        if !placeContext.isEmpty { parts.append(placeContext) }
        
        // Preferences
        for (key, value) in context.preferences {
            parts.append("\(key): \(value)")
        }
        
        // Strict instruction for repeat-frequency claims
        parts.append("STRICT RULE: Only mention familiarity or repeat frequency when Current scan evidence repeat_count is explicitly provided and >= 2. If repeat_count is 0 or 1, do NOT claim it's repeated. Never invent ordinal counts like second/third/fourth time.")
        
        return parts.joined(separator: "\n")
    }
    
    // MARK: - Persistence
    
    private func loadContext() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            context = try JSONDecoder().decode(UserContext.self, from: data)
        } catch {
            #if DEBUG
            print("⚠️ Failed to load user context: \(error)")
            #endif
        }
    }
    
    private func saveContext() {
        do {
            let data = try JSONEncoder().encode(context)
            try data.write(to: storageURL)
        } catch {
            #if DEBUG
            print("⚠️ Failed to save user context: \(error)")
            #endif
        }
    }
    
    func resetContext() {
        context = UserContext()
        saveContext()
    }
}

// MARK: - Models

struct UserContext: Codable {
    var totalScans: Int = 0
    var categoryCounts: [String: Int] = [:]
    var recentScans: [ScanHistoryItem] = []
    var lastScanDate: Date?
    var peopleSeen: [String: Int] = [:]
    var placesVisited: [String: Int] = [:]
    var preferences: [String: String] = [:]
    var knownProducts: [String: ProductMemory] = [:]
    var knownPets: [String: PetMemory] = [:]
}

struct ScanHistoryItem: Codable {
    let category: String
    let title: String
    let query: String
    let date: Date
    var details: [String: String] = [:]
}

struct ProductMemory: Codable {
    var name: String
    var brand: String
    var scanCount: Int
    var firstSeen: Date
    var lastSeen: Date
    var sizesSeen: [String: Int] // size string → count
    var category: String
}

struct PetMemory: Codable {
    var name: String
    var species: String        // "cat", "dog", etc.
    var visualDescription: String  // AI-generated description of markings, color, etc.
    var relationship: String   // "my cat", "neighbor's dog"
    var firstSeen: Date
    var lastSeen: Date
    var timesSeen: Int
}
