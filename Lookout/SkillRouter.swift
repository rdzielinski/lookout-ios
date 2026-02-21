//
//  SkillRouter.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/18/26.
//


import Foundation
import CoreLocation
import UIKit

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
    
    init(settings: SettingsManager) {
        self.settings = settings
        self.visionService = AIVisionService(settings: settings)
        registerSkills()
    }
    
    private func registerSkills() {
        skills[.flight] = FlightSkill(adsbAPIKey: settings.adsbExchangeAPIKey)
        skills[.landmark] = LandmarkSkill(googlePlacesAPIKey: settings.googlePlacesAPIKey)
        skills[.music] = MusicSkill()
        skills[.plant] = PlantSkill()
        skills[.vehicle] = VehicleSkill()
        skills[.product] = barcodeSkill
    }
    
    func refreshSkills() {
        registerSkills()
    }
    
    // MARK: - Turbo Pipeline
    //
    // OLD: Capture → AI API (2-5s) → Route to Skill (1-3s) → Result = 3-8s total
    // NEW: Capture → PreScan (200ms) → Start Skill + AI API in parallel → Merge → Result = 2-5s total
    //
    // The key insight: on-device Vision can predict the category fast enough to start
    // the downstream skill API call 2-3 seconds before the cloud AI returns.
    // If the AI agrees (which it does ~90% of the time), we've already got the skill
    // result waiting. If it disagrees, we re-route (small penalty, rare case).
    
    func processImage(_ imageData: Data, location: CLLocation?) async throws -> ProcessedResult {
        guard let image = UIImage(data: imageData) else {
            throw LookoutError.imageProcessingFailed
        }
        
        // Phase 1: Pre-scan + Face detection in parallel (~200ms)
        async let preScanTask = preScanRouter.preScan(imageData: imageData)
        async let faceTask = detectFaces(imageData: imageData)
        
        let preScan = await preScanTask
        let faceMatches = await faceTask
        
        // If barcode was found in pre-scan, fast path (skip AI entirely)
        if let preScan = preScan, let barcode = preScan.detectedBarcode {
            HapticService.shared.barcodeDetected()
            
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
            print("⚡ PreScan barcode fast-path: \(preScan.duration * 1000)ms")
            #endif
            
            return ProcessedResult(
                aiResponse: aiResponse,
                skillResult: result,
                faceMatches: faceMatches,
                nearbyPlace: checkNearbyPlace(location: location)
            )
        }
        
        // Phase 2: If pre-scan has a confident prediction, run skill + AI in parallel
        if let preScan = preScan, preScan.confidence >= 0.6, preScan.predictedCategory != .music {
            // Music is special — it needs to LISTEN, so we can't start it speculatively
            
            #if DEBUG
            print("⚡ PreScan predicted: \(preScan.predictedCategory.rawValue) (\(Int(preScan.confidence * 100))%) in \(Int(preScan.duration * 1000))ms")
            print("⚡ Starting parallel: skill(\(preScan.predictedCategory.rawValue)) + AI vision")
            #endif
            
            // Start skill + AI in parallel
            async let speculativeSkillTask = executeSkillSafe(
                category: preScan.predictedCategory,
                query: preScan.query,
                location: location
            )
            async let aiTask = visionService.analyzeImage(image)
            
            // Wait for both
            let speculativeResult = await speculativeSkillTask
            let aiResponse: AIVisionResponse
            
            do {
                aiResponse = try await aiTask
            } catch {
                // AI failed but we have a pre-scan result — use it as fallback
                if let specResult = speculativeResult {
                    let fallbackAI = AIVisionResponse(
                        category: preScan.predictedCategory.rawValue,
                        description: preScan.query,
                        query: preScan.query,
                        confidence: preScan.confidence
                    )
                    
                    recordScan(aiResponse: fallbackAI, result: specResult, location: location, faces: faceMatches)
                    
                    return ProcessedResult(
                        aiResponse: fallbackAI,
                        skillResult: specResult,
                        faceMatches: faceMatches,
                        nearbyPlace: checkNearbyPlace(location: location)
                    )
                }
                throw error
            }
            
            HapticService.shared.categorized()
            
            let aiCategory = aiResponse.skillCategory
            
            // Did AI agree with our pre-scan?
            if aiCategory == preScan.predictedCategory, let specResult = speculativeResult {
                // 🎯 HIT — AI confirmed pre-scan. Use the already-fetched skill result!
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
                    skillResult: result,
                    faceMatches: faceMatches,
                    nearbyPlace: nearbyPlace
                )
            } else {
                // ❌ MISS — AI disagreed. Re-route with AI's category (small penalty)
                #if DEBUG
                print("⚡ PreScan MISS: predicted \(preScan.predictedCategory.rawValue) but AI says \(aiCategory.rawValue). Re-routing...")
                #endif
                
                var result = try await routeToSkill(aiResponse: aiResponse, location: location)
                
                if aiCategory == .product {
                    result = await enrichWithPrice(result: result)
                }
                
                let nearbyPlace = checkNearbyPlace(location: location)
                recordScan(aiResponse: aiResponse, result: result, location: location, faces: faceMatches)
                
                return ProcessedResult(
                    aiResponse: aiResponse,
                    skillResult: result,
                    faceMatches: faceMatches,
                    nearbyPlace: nearbyPlace
                )
            }
        }
        
        // Phase 3: Low-confidence pre-scan or music — fall back to sequential pipeline
        #if DEBUG
        if let preScan = preScan {
            print("⚡ PreScan low confidence (\(Int(preScan.confidence * 100))%) or music. Using sequential pipeline.")
        } else {
            print("⚡ PreScan returned nil. Using sequential pipeline.")
        }
        #endif
        
        let aiResponse = try await visionService.analyzeImage(image)
        HapticService.shared.categorized()
        
        var result = try await routeToSkill(aiResponse: aiResponse, location: location)
        
        if aiResponse.skillCategory == .product {
            result = await enrichWithPrice(result: result)
        }
        
        let nearbyPlace = checkNearbyPlace(location: location)
        recordScan(aiResponse: aiResponse, result: result, location: location, faces: faceMatches)
        
        return ProcessedResult(
            aiResponse: aiResponse,
            skillResult: result,
            faceMatches: faceMatches,
            nearbyPlace: nearbyPlace
        )
    }
    
    // MARK: - Safe Skill Execution (doesn't throw — returns nil on failure)
    
    private func executeSkillSafe(category: SkillCategory, query: String, location: CLLocation?) async -> SkillResult? {
        do {
            if let skill = skills[category] {
                return try await skill.execute(query: query, location: location)
            }
            return nil
        } catch {
            #if DEBUG
            print("⚡ Speculative skill failed (expected, will use AI route): \(error.localizedDescription)")
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
    
    // MARK: - Skill Routing (used when pre-scan misses or low confidence)
    
    private func routeToSkill(aiResponse: AIVisionResponse, location: CLLocation?) async throws -> SkillResult {
        let category = aiResponse.skillCategory
        
        // Check if landmark matches a saved place first
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

// MARK: - Processed Result (includes face/place context)

struct ProcessedResult {
    let aiResponse: AIVisionResponse
    let skillResult: SkillResult
    let faceMatches: [FaceMatch]
    let nearbyPlace: SavedPlace?
}