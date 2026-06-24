//
//  OfflineVisionService.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/18/26.
//


import Foundation
import Vision
import UIKit
import CoreML
import NaturalLanguage

// MARK: - Offline Vision Service
/// Uses Apple's on-device Vision framework for basic classification when offline.
/// Supports: object classification, text recognition (OCR), barcode detection, animal detection.
/// Falls back gracefully when AI providers are unreachable.
class OfflineVisionService {

    private let lookoutClassifier = LookoutClassifierService()

    // MARK: - Offline Result
    struct OfflineResult {
        let title: String
        let category: SkillCategory
        let description: String
        let confidence: Double
        let details: [SkillResult.DetailItem]
        let source: String
        
        func toSkillResult() -> SkillResult {
            SkillResult(
                category: category,
                title: title,
                subtitle: description,
                details: details,
                sourceApp: source,
                deepLinkURL: nil
            )
        }
        
        func toAIResponse() -> AIVisionResponse {
            AIVisionResponse(
                category: category.rawValue,
                description: description,
                query: title,
                confidence: confidence
            )
        }
    }
    
    // MARK: - Analyze Image (Offline)
    
    /// Run all on-device classifiers in parallel and return the best result.
    func analyzeOffline(imageData: Data) async -> OfflineResult? {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else { return nil }

        // Try custom Lookout classifier first — direct SkillCategory output, sub-1ms
        if let custom = await lookoutClassifier.classify(cgImage), custom.confidence > 0.5 {
            let topPredictions = custom.allPredictions
                .prefix(3)
                .map { "\($0.category.rawValue) (\(Int($0.confidence * 100))%)" }
                .joined(separator: ", ")

            return OfflineResult(
                title: custom.category.displayName,
                category: custom.category,
                description: "On-device classification: \(custom.category.displayName) (\(Int(custom.confidence * 100))% confidence)",
                confidence: custom.confidence,
                details: [
                    .init(label: "Confidence", value: "\(Int(custom.confidence * 100))%", iconName: "chart.bar"),
                    .init(label: "Top Matches", value: topPredictions, iconName: "list.bullet"),
                    .init(label: "Mode", value: "Offline (on-device)", iconName: "iphone")
                ],
                source: "Lookout ML (Offline)"
            )
        }

        // Run all detectors in parallel
        async let classificationTask = classifyImage(cgImage)
        async let textTask = recognizeText(cgImage)
        async let barcodeTask = detectBarcode(cgImage)
        async let animalTask = detectAnimal(cgImage)
        
        let classification = await classificationTask
        let text = await textTask
        let barcode = await barcodeTask
        let animal = await animalTask
        
        // Priority: barcode > text (if substantial) > animal > general classification
        if let barcode {
            return barcode
        }
        
        if let text, text.confidence > 0.7 {
            return text
        }
        
        if let animal, animal.confidence > 0.5 {
            return animal
        }
        
        if let classification, classification.confidence > 0.3 {
            return classification
        }
        
        // If we got some text but low confidence, still return it
        if let text {
            return text
        }
        
        return classification
    }
    
    // MARK: - Image Classification (VNClassifyImageRequest)
    
    private func classifyImage(_ cgImage: CGImage) async -> OfflineResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<OfflineResult?, Never>) in            let request = VNClassifyImageRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNClassificationObservation],
                      let top = results.first,
                      top.confidence > 0.15 else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Get top 3 classifications for context
                let topResults: [VNClassificationObservation] = Array(results.prefix(5).filter { $0.confidence > 0.1 })
                let descriptions = topResults.map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
                
                // Map to Lookout category
                let category = self.mapToCategory(identifier: top.identifier, allResults: topResults)
                let cleanName = self.cleanIdentifier(top.identifier)
                
                var details: [SkillResult.DetailItem] = [
                    .init(label: "Confidence", value: "\(Int(top.confidence * 100))%", iconName: "chart.bar"),
                    .init(label: "Top Matches", value: descriptions.joined(separator: ", "), iconName: "list.bullet"),
                    .init(label: "Mode", value: "Offline (on-device)", iconName: "iphone")
                ]
                
                continuation.resume(returning: OfflineResult(
                    title: cleanName,
                    category: category,
                    description: "On-device classification: \(cleanName) (\(Int(top.confidence * 100))% confidence)",
                    confidence: Double(top.confidence),
                    details: details,
                    source: "Apple Vision (Offline)"
                ))
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - Text Recognition (OCR)
    
    private func recognizeText(_ cgImage: CGImage) async -> OfflineResult? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let allText = results.compactMap { $0.topCandidates(1).first?.string }
                guard !allText.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let fullText = allText.joined(separator: " ")
                let lineCount = allText.count
                let wordCount = fullText.split(separator: " ").count
                
                // Determine if this is significant text or just incidental
                let isSignificant = wordCount >= 3
                
                // Try to identify what kind of text
                let textType = self.identifyTextType(allText: allText, fullText: fullText)
                
                let truncated = fullText.prefix(200)
                let title = textType.title.isEmpty ? "Text Detected" : textType.title
                
                var details: [SkillResult.DetailItem] = [
                    .init(label: "Text", value: String(truncated), iconName: "doc.text"),
                    .init(label: "Lines", value: "\(lineCount)", iconName: "text.alignleft"),
                    .init(label: "Words", value: "\(wordCount)", iconName: "character.cursor.ibeam"),
                    .init(label: "Mode", value: "Offline OCR", iconName: "iphone")
                ]
                
                if !textType.type.isEmpty {
                    details.insert(
                        .init(label: "Type", value: textType.type, iconName: "tag"),
                        at: 0
                    )
                }
                
                continuation.resume(returning: OfflineResult(
                    title: title,
                    category: .product,
                    description: "Detected \(wordCount) words across \(lineCount) lines: \(truncated)",
                    confidence: isSignificant ? 0.8 : 0.4,
                    details: details,
                    source: "Apple Vision OCR (Offline)"
                ))
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - Barcode Detection
    
    private func detectBarcode(_ cgImage: CGImage) async -> OfflineResult? {
        await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNBarcodeObservation],
                      let barcode = results.first,
                      let payload = barcode.payloadStringValue else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let symbology = barcode.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                
                let details: [SkillResult.DetailItem] = [
                    .init(label: "Barcode", value: payload, iconName: "barcode"),
                    .init(label: "Type", value: symbology, iconName: "qrcode"),
                    .init(label: "Mode", value: "Offline scan", iconName: "iphone"),
                    .init(label: "Note", value: "Connect to internet for product lookup", iconName: "wifi.slash")
                ]
                
                continuation.resume(returning: OfflineResult(
                    title: "Barcode: \(payload)",
                    category: .product,
                    description: "\(symbology) barcode detected: \(payload). Connect to internet for full product details.",
                    confidence: 1.0,
                    details: details,
                    source: "Apple Vision (Offline)"
                ))
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - Animal Detection
    
    private func detectAnimal(_ cgImage: CGImage) async -> OfflineResult? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeAnimalsRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedObjectObservation],
                      let animal = results.first else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let labels = animal.labels.map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
                let topLabel = animal.labels.first?.identifier ?? "Animal"
                let confidence = Double(animal.labels.first?.confidence ?? 0)
                
                let details: [SkillResult.DetailItem] = [
                    .init(label: "Animal", value: topLabel.capitalized, iconName: "pawprint.fill"),
                    .init(label: "Confidence", value: "\(Int(confidence * 100))%", iconName: "chart.bar"),
                    .init(label: "All Matches", value: labels.joined(separator: ", "), iconName: "list.bullet"),
                    .init(label: "Mode", value: "Offline (on-device)", iconName: "iphone"),
                    .init(label: "Tip", value: "Connect to internet for species details from iNaturalist", iconName: "wifi.slash")
                ]
                
                continuation.resume(returning: OfflineResult(
                    title: topLabel.capitalized,
                    category: .plant, // plant/animal category
                    description: "On-device animal detection: \(topLabel.capitalized)",
                    confidence: confidence,
                    details: details,
                    source: "Apple Vision (Offline)"
                ))
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - Helpers
    
    /// Map Vision classification identifiers to Lookout skill categories.
    private func mapToCategory(identifier: String, allResults: [VNClassificationObservation]) -> SkillCategory {
        let id = identifier.lowercased()
        let allIds = allResults.map { $0.identifier.lowercased() }
        
        // Vehicle keywords
        let vehicleWords = ["car", "vehicle", "truck", "suv", "sedan", "coupe", "minivan", "bus",
                           "motorcycle", "convertible", "pickup", "jeep", "taxi", "ambulance",
                           "fire_engine", "police_van", "sports_car", "station_wagon"]
        if vehicleWords.contains(where: { id.contains($0) }) { return .vehicle }
        
        // Plant/animal keywords
        let natureWords = ["flower", "plant", "tree", "leaf", "bird", "dog", "cat", "fish",
                          "insect", "butterfly", "mushroom", "garden", "animal", "pet",
                          "daisy", "rose", "sunflower", "tulip", "fern", "moss"]
        if natureWords.contains(where: { id.contains($0) }) { return .plant }
        
        // Building/landmark
        let buildingWords = ["church", "castle", "palace", "mosque", "temple", "monastery",
                            "bridge", "tower", "dome", "lighthouse", "monument", "fountain",
                            "building", "skyscraper", "stadium", "theater", "cathedral"]
        if buildingWords.contains(where: { id.contains($0) }) { return .landmark }
        
        // Music
        let musicWords = ["guitar", "piano", "drum", "violin", "saxophone", "trumpet",
                         "harmonica", "accordion", "banjo", "flute", "cello"]
        if musicWords.contains(where: { id.contains($0) }) { return .product }
        
        return .unknown
    }
    
    /// Clean up Vision framework identifier strings for display.
    private func cleanIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
    
    /// Identify what kind of text was detected.
    private func identifyTextType(allText: [String], fullText: String) -> (title: String, type: String) {
        let lower = fullText.lowercased()
        
        // URL
        if lower.contains("http") || lower.contains("www.") || lower.contains(".com") {
            let url = allText.first { $0.lowercased().contains("http") || $0.lowercased().contains("www") || $0.lowercased().contains(".com") }
            return (url ?? "URL Detected", "Website / URL")
        }
        
        // Phone number
        let phonePattern = #"\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#
        if lower.range(of: phonePattern, options: .regularExpression) != nil {
            return ("Phone Number Detected", "Phone Number")
        }
        
        // Email
        if lower.contains("@") && lower.contains(".") {
            let email = allText.first { $0.contains("@") }
            return (email ?? "Email Detected", "Email Address")
        }
        
        // Price / money
        if lower.contains("$") || lower.range(of: #"\d+\.\d{2}"#, options: .regularExpression) != nil {
            return ("Price / Label Detected", "Price Tag")
        }
        
        // Sign / notice
        if allText.count <= 5 && allText.contains(where: { $0.count > 3 && $0 == $0.uppercased() }) {
            return (allText.first { $0.count > 2 } ?? "Sign", "Sign / Notice")
        }
        
        // Menu
        if lower.contains("menu") || (lower.contains("$") && allText.count > 5) {
            return ("Menu Detected", "Menu")
        }
        
        // Default — first meaningful line as title
        let titleLine = allText.first { $0.trimmingCharacters(in: .whitespaces).count > 2 } ?? "Text"
        return (String(titleLine.prefix(50)), "")
    }
    
    // MARK: - Network Check
    
    /// Quick check if we can reach the internet.
    static func isOffline() async -> Bool {
        guard let url = URL(string: "https://api.anthropic.com") else { return true }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode >= 500
            }
            return false
        } catch {
            return true
        }
    }
}
