import Foundation
import CoreML
import Vision
import UIKit

// MARK: - Lookout Category Classifier
/// Uses a custom Create ML–trained Core ML model to classify images
/// directly into Lookout's SkillCategory cases.
///
/// This replaces the generic VNClassifyImageRequest in OfflineVisionService
/// with a model trained specifically on Lookout's categories:
/// flight, landmark, plant, vehicle, product, music, unknown.
///
/// SETUP:
/// 1. Train a model in Create ML (see training guide)
/// 2. Drag the exported LookoutClassifier.mlmodel into Xcode
/// 3. Xcode auto-generates a `LookoutClassifier` Swift class
/// 4. This service wraps it with Vision for easy integration

class LookoutClassifierService {
    
    // MARK: - Classification Result
    struct Classification {
        let category: SkillCategory
        let confidence: Double
        let allPredictions: [(category: SkillCategory, confidence: Double)]
        let inferenceTimeMs: Double
    }
    
    // MARK: - Properties
    
    /// The compiled Core ML model, loaded once at init
    private var model: VNCoreMLModel?
    
    /// Whether the custom model loaded successfully
    var isAvailable: Bool { model != nil }
    
    // MARK: - Init
    
    init() {
        loadModel()
    }
    
    private func loadModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all // Use Neural Engine when available

            let bundle = Bundle.main

            // First try to load a compiled model (.mlmodelc)
            if let modelURL = bundle.url(forResource: "LookoutClassifier", withExtension: "mlmodelc") {
                let coreMLModel = try MLModel(contentsOf: modelURL, configuration: config)
                self.model = try VNCoreMLModel(for: coreMLModel)
                print("✅ LookoutClassifier (.mlmodelc) loaded successfully")
                return
            }

            // If not compiled, try to find the raw .mlmodel and compile it at runtime (dev builds)
            if let rawModelURL = bundle.url(forResource: "LookoutClassifier", withExtension: "mlmodel") {
                let compiledURL = try MLModel.compileModel(at: rawModelURL)
                let coreMLModel = try MLModel(contentsOf: compiledURL, configuration: config)
                self.model = try VNCoreMLModel(for: coreMLModel)
                print("✅ LookoutClassifier (.mlmodel compiled at runtime) loaded successfully")
                return
            }

            // Not found in bundle
            print("⚠️ LookoutClassifier model file not found in bundle (neither .mlmodelc nor .mlmodel). Falling back to generic Vision classifier.")
        } catch {
            print("⚠️ LookoutClassifier not available: \(error.localizedDescription)")
            print("   Falling back to generic Vision classifier")
            // This is fine — the app works without it, just uses generic classification
        }
    }
    
    // MARK: - Classify Image
    
    /// Classify an image using the custom Lookout model.
    /// Returns nil if the model isn't loaded (falls back to generic Vision).
    func classify(_ cgImage: CGImage) async -> Classification? {
        guard let model else { return nil }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        return await withCheckedContinuation { (continuation: CheckedContinuation<Classification?, Never>) in
            let request = VNCoreMLRequest(model: model) { request, error in
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                guard error == nil,
                      let results = request.results as? [VNClassificationObservation],
                      let top = results.first else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Map all predictions to SkillCategory
                let allPredictions: [(category: SkillCategory, confidence: Double)] = results
                    .prefix(7)
                    .compactMap { obs in
                        guard let category = SkillCategory(rawValue: obs.identifier) else { return nil }
                        return (category: category, confidence: Double(obs.confidence))
                    }
                
                let topCategory = SkillCategory(rawValue: top.identifier) ?? .unknown
                
                let classification = Classification(
                    category: topCategory,
                    confidence: Double(top.confidence),
                    allPredictions: allPredictions,
                    inferenceTimeMs: elapsed
                )
                
                continuation.resume(returning: classification)
            }
            
            // Match the crop/scale behavior used during training
            request.imageCropAndScaleOption = .centerCrop
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - Classify UIImage (convenience)
    
    func classify(_ image: UIImage) async -> Classification? {
        guard let cgImage = image.cgImage else { return nil }
        return await classify(cgImage)
    }
    
    // MARK: - Classify Image Data (convenience)
    
    func classify(imageData: Data) async -> Classification? {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else { return nil }
        return await classify(cgImage)
    }
}

