import Foundation
import CoreLocation
import UIKit

// MARK: - Routing Decision (for debug trace)
struct RoutingDecision {
    let reason: String
    let matchedKeyword: String?
}

// MARK: - Skill Router (Turbo Pipeline)
class SkillRouter: ObservableObject {
    private let settings: SettingsManager
    private let visionService: AIVisionService
    private let barcodeSkill = BarcodeSkill()
    private let priceLookup = PriceLookupService()
    private let preScanRouter = PreScanRouter()
    private var skills: [SkillCategory: LookoutSkill] = [:]
    
    // Memory services (injected from ViewModel)
    var faceMemory: FaceMemoryService?
    var placeMemory: PlaceMemoryService?
    var userContext: UserContextStore?
    
    // Debug accessors
    var debugVisionProviderName: String { visionService.debugProviderName }
    var debugVisionSystemPrompt: String { visionService.debugSystemPromptText }
    
    init(settings: SettingsManager) {
        self.settings = settings
        self.visionService = AIVisionService(settings: settings)
        registerSkills()
    }
    
    private func registerSkills() {
        skills[.flight] = FlightSkill(fr24APIKey: settings.flightradar24APIKey, adsbAPIKey: settings.adsbExchangeAPIKey)
        skills[.landmark] = LandmarkSkill(googlePlacesAPIKey: settings.googlePlacesAPIKey)
        skills[.music] = MusicSkill()
        skills[.plant] = PlantSkill()
        skills[.vehicle] = VehicleSkill()
        skills[.product] = barcodeSkill
        skills[.translation] = TranslationSkill(settings: settings)
        skills[.food] = FoodSkill(settings: settings)
        skills[.drink] = DrinkSkill(settings: settings)
        skills[.receipt] = ReceiptSkill(settings: settings)
        skills[.medication] = MedicationSkill()
        skills[.book] = BookSkill()
        skills[.businessCard] = BusinessCardSkill(settings: settings)
        skills[.qrCode] = QRCodeSkill()
    }
    
    func refreshSkills() {
        registerSkills()
    }
    
    // MARK: - Turbo Pipeline
    //
    // OLD: Capture → AI API (2-5s) → Route to Skill (1-3s) → Result = 3-8s total
    // NEW: Capture → PreScan (200ms) → Start Skill + AI API in parallel → Merge → Result = 2-5s total
    
    func processImage(
        _ imageData: Data,
        location: CLLocation?,
        environment: ScanEnvironmentSignals? = nil,
        onStatusUpdate: ((LookoutQuery.QueryStatus) -> Void)? = nil
    ) async throws -> ProcessedResult {
        guard let image = UIImage(data: imageData) else {
            throw LookoutError.imageProcessingFailed
        }
        
        onStatusUpdate?(.analyzing)
        
        // Phase 1: Pre-scan + Face detection in parallel (~200ms)
        async let preScanTask = preScanRouter.preScan(imageData: imageData)
        async let faceTask = detectFaces(imageData: imageData)
        
        let preScan = await preScanTask
        let faceMatches = await faceTask
        
        // If QR code was detected in pre-scan, fast path (skip AI)
        if let preScan = preScan, preScan.predictedCategory == .qrCode, preScan.confidence >= 1.0 {
            HapticService.shared.barcodeDetected()
            onStatusUpdate?(.executingQRCode)

            let aiResponse = AIVisionResponse(
                category: "qrCode",
                description: "QR code detected",
                query: preScan.query,
                confidence: 1.0
            )
            let result = try await (skills[.qrCode] ?? QRCodeSkill()).execute(query: preScan.query, location: location)

            recordScan(aiResponse: aiResponse, result: result, location: location, faces: faceMatches)

            return ProcessedResult(
                aiResponse: aiResponse,
                rawAIResponse: aiResponse,
                skillResult: result,
                faceMatches: faceMatches,
                nearbyPlace: checkNearbyPlace(location: location),
                environment: environment,
                routingDecision: RoutingDecision(reason: "QR code pre-scan fast-path", matchedKeyword: preScan.query)
            )
        }

        // If barcode was found in pre-scan, fast path (skip AI entirely)
        if let preScan = preScan, let barcode = preScan.detectedBarcode {
            HapticService.shared.barcodeDetected()
            onStatusUpdate?(.executingProduct)
            
            let aiResponse = AIVisionResponse(
                category: "product",
                description: "Barcode detected: \(barcode)",
                query: barcode,
                confidence: 1.0
            )
            var result = try await barcodeSkill.execute(query: barcode, location: location)
            result = await enrichWithPrice(result: result)
            
            recordScan(aiResponse: aiResponse, result: result, location: location, faces: faceMatches)
            
            #if DEBUG
            print("⚡ PreScan barcode fast-path: \(Int(preScan.duration * 1000))ms")
            #endif
            
            return ProcessedResult(
                aiResponse: aiResponse,
                rawAIResponse: aiResponse,
                skillResult: result,
                faceMatches: faceMatches,
                nearbyPlace: checkNearbyPlace(location: location),
                environment: environment,
                routingDecision: RoutingDecision(reason: "Barcode pre-scan fast-path", matchedKeyword: barcode)
            )
        }
        
        // Phase 2: If pre-scan has a confident prediction, run skill + AI in parallel
        let effectiveCategory = adjustForEnvironment(preScan: preScan, environment: environment)
        
        if let preScan = preScan, effectiveCategory.confidence >= 0.6, effectiveCategory.category != .music {
            
            #if DEBUG
            print("⚡ PreScan predicted: \(effectiveCategory.category.rawValue) (\(Int(effectiveCategory.confidence * 100))%) in \(Int(preScan.duration * 1000))ms")
            print("⚡ Starting parallel: skill(\(effectiveCategory.category.rawValue)) + AI vision")
            #endif
            
            onStatusUpdate?(.routing)
            
            // Start skill + AI in parallel
            async let speculativeSkillTask = executeSkillSafe(
                category: effectiveCategory.category,
                query: preScan.query,
                location: location
            )
            async let aiTask = visionService.analyzeImage(image)
            
            let speculativeResult = await speculativeSkillTask
            let aiResponse: AIVisionResponse
            
            do {
                aiResponse = try await aiTask
            } catch {
                // AI failed but we have a pre-scan result — use it as fallback
                if let specResult = speculativeResult {
                    let fallbackAI = AIVisionResponse(
                        category: effectiveCategory.category.rawValue,
                        description: preScan.query,
                        query: preScan.query,
                        confidence: effectiveCategory.confidence
                    )
                    
                    recordScan(aiResponse: fallbackAI, result: specResult, location: location, faces: faceMatches)
                    
                    return ProcessedResult(
                        aiResponse: fallbackAI,
                        rawAIResponse: fallbackAI,
                        skillResult: specResult,
                        faceMatches: faceMatches,
                        nearbyPlace: checkNearbyPlace(location: location),
                        environment: environment,
                        routingDecision: RoutingDecision(
                            reason: "AI failed, used pre-scan fallback (\(effectiveCategory.category.rawValue))",
                            matchedKeyword: preScan.topClassifications.first
                        )
                    )
                }
                throw error
            }
            
            HapticService.shared.categorized()
            
            let aiCategory = aiResponse.skillCategory
            onStatusUpdate?(Self.executingStatus(for: aiCategory))
            
            // Did AI agree with our pre-scan?
            if aiCategory == effectiveCategory.category, let specResult = speculativeResult {
                // 🎯 HIT
                #if DEBUG
                print("⚡ PreScan HIT! AI agreed with pre-scan. Skill result was ready.")
                #endif
                
                var result = specResult
                if aiCategory == .product {
                    result = await enrichWithPrice(result: result)
                }
                
                let nearbyPlace = checkNearbyPlace(location: location)
                recordScan(aiResponse: aiResponse, result: result, location: location, faces: faceMatches)
                
                return ProcessedResult(
                    aiResponse: aiResponse,
                    rawAIResponse: aiResponse,
                    skillResult: result,
                    faceMatches: faceMatches,
                    nearbyPlace: nearbyPlace,
                    environment: environment,
                    routingDecision: RoutingDecision(
                        reason: "PreScan HIT — parallel pipeline, \(effectiveCategory.category.rawValue) confirmed by AI",
                        matchedKeyword: preScan.topClassifications.first
                    )
                )
            } else {
                // ❌ MISS — Re-route with AI's category
                #if DEBUG
                print("⚡ PreScan MISS: predicted \(effectiveCategory.category.rawValue) but AI says \(aiCategory.rawValue). Re-routing...")
                #endif
                
                var result = try await routeToSkill(aiResponse: aiResponse, location: location)
                
                if aiCategory == .product {
                    result = await enrichWithPrice(result: result)
                }
                
                let nearbyPlace = checkNearbyPlace(location: location)
                recordScan(aiResponse: aiResponse, result: result, location: location, faces: faceMatches)
                
                return ProcessedResult(
                    aiResponse: aiResponse,
                    rawAIResponse: aiResponse,
                    skillResult: result,
                    faceMatches: faceMatches,
                    nearbyPlace: nearbyPlace,
                    environment: environment,
                    routingDecision: RoutingDecision(
                        reason: "PreScan MISS — predicted \(effectiveCategory.category.rawValue) but AI routed to \(aiCategory.rawValue)",
                        matchedKeyword: preScan.topClassifications.first
                    )
                )
            }
        }
        
        // Phase 3: Low-confidence pre-scan or music — sequential pipeline
        #if DEBUG
        if let preScan = preScan {
            print("⚡ PreScan low confidence (\(Int(effectiveCategory.confidence * 100))%) or music. Sequential pipeline.")
        } else {
            print("⚡ PreScan returned nil. Sequential pipeline.")
        }
        #endif
        
        onStatusUpdate?(.routing)
        
        let aiResponse = try await visionService.analyzeImage(image)
        HapticService.shared.categorized()
        
        onStatusUpdate?(Self.executingStatus(for: aiResponse.skillCategory))
        
        var result = try await routeToSkill(aiResponse: aiResponse, location: location)
        
        if aiResponse.skillCategory == .product {
            result = await enrichWithPrice(result: result)
        }
        
        let nearbyPlace = checkNearbyPlace(location: location)
        recordScan(aiResponse: aiResponse, result: result, location: location, faces: faceMatches)
        
        return ProcessedResult(
            aiResponse: aiResponse,
            rawAIResponse: aiResponse,
            skillResult: result,
            faceMatches: faceMatches,
            nearbyPlace: nearbyPlace,
            environment: environment,
            routingDecision: RoutingDecision(
                reason: "Sequential pipeline — \(preScan == nil ? "no pre-scan" : "low confidence or music")",
                matchedKeyword: preScan?.topClassifications.first
            )
        )
    }
    
    // MARK: - Environment-Adjusted Prediction
    
    private func adjustForEnvironment(
        preScan: PreScanRouter.PreScanResult?,
        environment: ScanEnvironmentSignals?
    ) -> (category: SkillCategory, confidence: Double) {
        guard let preScan = preScan else {
            return (.unknown, 0.0)
        }
        
        var category = preScan.predictedCategory
        var confidence = preScan.confidence
        
        if let env = environment {
            // At a music venue: lower confidence so we fall through to sequential
            // (lets AI + Shazam handle it properly)
            if env.placeType == .musicVenue {
                if category == .unknown || category == .landmark {
                    confidence = max(confidence - 0.2, 0.0)
                }
            }
            
            // Very loud ambient → could be a concert, lower confidence for sequential
            if let db = env.ambientDecibels, db > -20 {
                if category == .unknown {
                    confidence = max(confidence - 0.15, 0.0)
                }
            }
            
            // At a retail area, boost product confidence
            if env.placeType == .retailArea && category == .product {
                confidence = min(confidence + 0.1, 0.95)
            }
        }
        
        return (category, confidence)
    }
    
    // MARK: - Category → QueryStatus Mapping
    
    static func executingStatus(for category: SkillCategory) -> LookoutQuery.QueryStatus {
        switch category {
        case .flight:       return .executingFlight
        case .landmark:     return .executingLandmark
        case .music:        return .executingMusic
        case .plant:        return .executingPlant
        case .vehicle:      return .executingVehicle
        case .product:      return .executingProduct
        case .translation:  return .executingTranslation
        case .food:         return .executingFood
        case .drink:        return .executingDrink
        case .receipt:      return .executingReceipt
        case .medication:   return .executingMedication
        case .book:         return .executingBook
        case .businessCard: return .executingBusinessCard
        case .qrCode:       return .executingQRCode
        case .unknown:      return .executingGeneral
        }
    }
    
    // MARK: - Safe Skill Execution (doesn't throw)
    
    private func executeSkillSafe(category: SkillCategory, query: String, location: CLLocation?) async -> SkillResult? {
        do {
            if let skill = skills[category] {
                return try await skill.execute(query: query, location: location)
            }
            return nil
        } catch {
            #if DEBUG
            print("⚡ Speculative skill failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
    
    // MARK: - Face Detection
    
    private func detectFaces(imageData: Data) async -> [FaceMatch] {
        guard settings.faceRecognitionEnabled, let faceMemory = faceMemory else { return [] }
        return await faceMemory.detectAndMatch(imageData: imageData)
    }
    
    // MARK: - Place Check
    
    private func checkNearbyPlace(location: CLLocation?) -> SavedPlace? {
        guard settings.placeMemoryEnabled, let location = location, let placeMemory = placeMemory else { return nil }
        return placeMemory.findNearbyPlace(location: location)
    }
    
    // MARK: - Price Enrichment
    
    private func enrichWithPrice(result: SkillResult) async -> SkillResult {
        let productName = result.title
        let brand = result.subtitle
        let category = result.details.first(where: { $0.label == "Category" })?.value ?? ""
        
        if let price = await priceLookup.estimatePrice(productName: productName, brand: brand, category: category) {
            var newDetails = result.details
            newDetails.append(SkillResult.DetailItem(label: "Est. Price", value: price, iconName: "dollarsign.circle"))
            
            return SkillResult(
                category: result.category,
                title: result.title,
                subtitle: result.subtitle,
                details: newDetails,
                sourceApp: result.sourceApp,
                deepLinkURL: result.deepLinkURL
            )
        }
        
        return result
    }
    
    // MARK: - Record Scan
    
    private func recordScan(aiResponse: AIVisionResponse, result: SkillResult, location: CLLocation?, faces: [FaceMatch]) {
        userContext?.recordScan(category: aiResponse.category, query: aiResponse.query, title: result.title)
        
        for face in faces where face.name != nil {
            userContext?.recordFaceRecognition(name: face.name!)
            faceMemory?.markSeen(name: face.name!)
        }
        
        if let place = checkNearbyPlace(location: location) {
            userContext?.recordPlaceVisit(name: place.name)
            placeMemory?.markVisited(name: place.name)
        }
    }
    
    // MARK: - Skill Routing
    
    private func routeToSkill(aiResponse: AIVisionResponse, location: CLLocation?) async throws -> SkillResult {
        let category = aiResponse.skillCategory
        
        if category == .landmark, settings.placeMemoryEnabled, let location = location, let placeMemory = placeMemory {
            if let nearby = placeMemory.findNearbyPlace(location: location) {
                return SkillResult(
                    category: .landmark,
                    title: nearby.name,
                    subtitle: aiResponse.description,
                    details: [
                        .init(label: "Your Note", value: nearby.notes.isEmpty ? "Saved location" : nearby.notes, iconName: "bookmark.fill"),
                        .init(label: "Category", value: nearby.category.rawValue, iconName: nearby.category.iconName),
                        .init(label: "Visits", value: "\(nearby.visitCount)", iconName: "figure.walk"),
                        .init(label: "Last Visit", value: formatDate(nearby.lastVisited), iconName: "clock")
                    ],
                    sourceApp: "Lookout Memory",
                    deepLinkURL: nil
                )
            }
        }
        
        if category == .music, let musicSkill = skills[.music] as? MusicSkill {
            return try await musicSkill.executeAndGetResult(query: aiResponse.query, location: location)
        }
        
        if let skill = skills[category] {
            return try await skill.execute(query: aiResponse.query, location: location)
        }
        
        return SkillResult(
            category: category,
            title: "Identified: \(category.displayName)",
            subtitle: aiResponse.description,
            details: [
                .init(label: "Description", value: aiResponse.description, iconName: "eye"),
                .init(label: "Confidence", value: "\(Int(aiResponse.confidence * 100))%", iconName: "chart.bar"),
                .init(label: "Query", value: aiResponse.query, iconName: "magnifyingglass")
            ],
            sourceApp: "Lookout AI",
            deepLinkURL: nil
        )
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    var availableSkills: [SkillCategory] {
        Array(skills.keys).sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Processed Result

struct ProcessedResult {
    let aiResponse: AIVisionResponse
    let rawAIResponse: AIVisionResponse
    let skillResult: SkillResult
    let faceMatches: [FaceMatch]
    let nearbyPlace: SavedPlace?
    let environment: ScanEnvironmentSignals?
    let routingDecision: RoutingDecision
}
