import Foundation
import Vision
import UIKit
import CoreImage

// MARK: - PreScan Router
// Uses Apple's on-device Vision framework to predict the skill category in ~200ms
// This runs BEFORE the AI API call, allowing the skill to start fetching in parallel

class PreScanRouter {
    
    // MARK: - PreScan Result
    struct PreScanResult {
        let predictedCategory: SkillCategory
        let confidence: Double
        let query: String          // Best-effort query for the skill
        let detectedText: [String] // Any text found in the image
        let detectedBarcode: String? // Barcode payload if found
        let isAnimal: Bool
        let topClassifications: [String] // Top VNClassification labels
        let duration: TimeInterval // How long the pre-scan took
    }
    
    // MARK: - Run All Detectors in Parallel
    
    func preScan(imageData: Data) async -> PreScanResult? {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return nil }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Run all Vision requests in parallel
        async let classifyTask = classifyImage(cgImage)
        async let textTask = recognizeText(cgImage)
        async let barcodeTask = detectBarcodes(cgImage)
        async let animalTask = detectAnimals(cgImage)
        
        let classifications = await classifyTask
        let texts = await textTask
        let barcode = await barcodeTask
        let animalResults = await animalTask
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        // If barcode found, that's the fastest path — product category, done
        if let barcode = barcode {
            return PreScanResult(
                predictedCategory: .product,
                confidence: 1.0,
                query: barcode,
                detectedText: texts,
                detectedBarcode: barcode,
                isAnimal: false,
                topClassifications: classifications.map { $0.label },
                duration: duration
            )
        }
        
        // Determine category from Vision classifications + context
        let prediction = predictCategory(
            classifications: classifications,
            texts: texts,
            hasAnimal: !animalResults.isEmpty,
            animalLabels: animalResults
        )
        
        return PreScanResult(
            predictedCategory: prediction.category,
            confidence: prediction.confidence,
            query: prediction.query,
            detectedText: texts,
            detectedBarcode: nil,
            isAnimal: !animalResults.isEmpty,
            topClassifications: classifications.map { $0.label },
            duration: duration
        )
    }
    
    // MARK: - VNClassifyImageRequest (~100-150ms)
    
    private struct Classification {
        let label: String
        let confidence: Float
    }
    
    private func classifyImage(_ cgImage: CGImage) async -> [Classification] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Classification], Never>) in
            let request = VNClassifyImageRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let top = results.prefix(10)
                    .filter { $0.confidence > 0.05 }
                    .map { Classification(label: $0.identifier, confidence: $0.confidence) }
                
                continuation.resume(returning: top)
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
    
    // MARK: - VNRecognizeTextRequest (~50-100ms)
    
    private func recognizeText(_ cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let texts = results.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: texts)
            }
            request.recognitionLevel = .fast // Speed over accuracy for pre-scan
            request.usesLanguageCorrection = false
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
    
    // MARK: - VNDetectBarcodesRequest (~30-50ms)
    
    private func detectBarcodes(_ cgImage: CGImage) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let request = VNDetectBarcodesRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNBarcodeObservation],
                      let barcode = results.first,
                      let payload = barcode.payloadStringValue else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: payload)
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - VNRecognizeAnimalsRequest (~50-80ms)
    
    private func detectAnimals(_ cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let request = VNRecognizeAnimalsRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedObjectObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let labels = results.flatMap { $0.labels.map { $0.identifier } }
                continuation.resume(returning: labels)
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
    
    // MARK: - Category Prediction Logic
    
    private struct Prediction {
        let category: SkillCategory
        let confidence: Double
        let query: String
    }
    
    private func predictCategory(
        classifications: [Classification],
        texts: [String],
        hasAnimal: Bool,
        animalLabels: [String]
    ) -> Prediction {
        
        let labels = Set(classifications.map { $0.label.lowercased() })
        let allText = texts.joined(separator: " ").lowercased()
        let topLabel = classifications.first?.label.lowercased() ?? ""
        let topConfidence = Double(classifications.first?.confidence ?? 0)
        
        // --- ANIMAL/PLANT detection (high confidence from dedicated detector) ---
        if hasAnimal {
            let animalQuery = animalLabels.first ?? topLabel
            return Prediction(category: .plant, confidence: 0.85, query: animalQuery)
        }
        
        // --- PLANT keywords in classification ---
        let plantKeywords: Set<String> = [
            "flower", "plant", "tree", "leaf", "garden", "grass", "mushroom",
            "succulent", "fern", "moss", "vine", "shrub", "herb", "blossom",
            "petal", "seed", "fruit", "vegetable", "daisy", "rose", "tulip",
            "sunflower", "orchid", "cactus", "palm_tree", "pine_tree"
        ]
        if labels.contains(where: { label in plantKeywords.contains(where: { label.contains($0) }) }) {
            let query = classifications.first.map { cleanIdentifier($0.label) } ?? "plant"
            return Prediction(category: .plant, confidence: min(topConfidence + 0.1, 0.9), query: query)
        }
        
        // --- VEHICLE detection ---
        let vehicleKeywords: Set<String> = [
            "car", "vehicle", "truck", "motorcycle", "bus", "van", "suv",
            "sedan", "convertible", "pickup", "minivan", "sports_car",
            "racing_car", "ambulance", "fire_engine", "police_car", "taxi",
            "bicycle", "scooter", "moped", "tractor", "boat", "ship"
        ]
        if labels.contains(where: { label in vehicleKeywords.contains(where: { label.contains($0) }) }) {
            let query = classifications.prefix(3).map { cleanIdentifier($0.label) }.joined(separator: " ")
            return Prediction(category: .vehicle, confidence: min(topConfidence + 0.1, 0.9), query: query)
        }
        
        // --- FLIGHT detection ---
        let flightKeywords: Set<String> = [
            "airplane", "aircraft", "airliner", "jet", "helicopter",
            "drone", "warplane", "biplane", "airship"
        ]
        if labels.contains(where: { label in flightKeywords.contains(where: { label.contains($0) }) }) {
            let query = classifications.first.map { cleanIdentifier($0.label) } ?? "aircraft"
            return Prediction(category: .flight, confidence: min(topConfidence + 0.1, 0.9), query: query)
        }
        
        // --- LANDMARK detection (buildings + text for signs) ---
        let landmarkKeywords: Set<String> = [
            "building", "church", "castle", "tower", "bridge", "monument",
            "mosque", "temple", "palace", "cathedral", "skyscraper",
            "lighthouse", "arch", "dome", "fountain", "statue", "museum",
            "library", "barn", "house", "cabin", "storefront"
        ]
        if labels.contains(where: { label in landmarkKeywords.contains(where: { label.contains($0) }) }) {
            // If text was detected, include it as query context
            let textHint = texts.prefix(3).joined(separator: " ")
            let classHint = classifications.first.map { cleanIdentifier($0.label) } ?? "building"
            let query = textHint.isEmpty ? classHint : "\(classHint) \(textHint)"
            return Prediction(category: .landmark, confidence: min(topConfidence + 0.05, 0.85), query: query)
        }
        
        // --- PRODUCT detection (packaged goods, electronics, etc.) ---
        let productKeywords: Set<String> = [
            "bottle", "can", "box", "package", "container", "carton",
            "laptop", "phone", "keyboard", "mouse", "monitor", "headphone",
            "speaker", "camera", "remote", "controller", "watch", "glasses",
            "shoe", "sneaker", "bag", "backpack", "suitcase", "envelope",
            "book", "magazine", "newspaper", "pen", "pencil", "cup", "mug",
            "plate", "bowl", "fork", "knife", "spoon", "toothbrush"
        ]
        if labels.contains(where: { label in productKeywords.contains(where: { label.contains($0) }) }) {
            // Include any detected text (brand names, labels)
            let textHint = texts.prefix(3).joined(separator: " ")
            let classHint = classifications.first.map { cleanIdentifier($0.label) } ?? "product"
            let query = textHint.isEmpty ? classHint : textHint
            return Prediction(category: .product, confidence: min(topConfidence + 0.05, 0.8), query: query)
        }
        
        // --- TEXT-heavy images → likely landmark/sign or product ---
        if texts.count > 3 {
            let query = texts.prefix(5).joined(separator: " ")
            return Prediction(category: .landmark, confidence: 0.5, query: query)
        }
        
        // --- Fallback: use top classification but low confidence ---
        let fallbackQuery = classifications.prefix(3).map { cleanIdentifier($0.label) }.joined(separator: ", ")
        return Prediction(category: .unknown, confidence: max(topConfidence, 0.3), query: fallbackQuery)
    }
    
    // MARK: - Helpers
    
    private func cleanIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
