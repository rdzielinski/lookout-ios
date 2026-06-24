//
//  LookoutClassifierService.swift
//  Lookout
//

import Foundation
import CoreML
import Vision
import UIKit

class LookoutClassifierService {

    struct ClassificationResult {
        let category: SkillCategory
        let confidence: Double
        let allPredictions: [(category: SkillCategory, confidence: Double)]
    }

    private var model: VNCoreMLModel?

    init() {
        loadModel()
    }

    var isAvailable: Bool { model != nil }

    private func loadModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let classifier = try LookoutClassifier(configuration: config)
            model = try VNCoreMLModel(for: classifier.model)
        } catch {
            #if DEBUG
            print("⚠️ LookoutClassifier model not available: \(error.localizedDescription)")
            print("⚠️ Falling back to generic Vision classification")
            #endif
            model = nil
        }
    }

    func classify(_ cgImage: CGImage) async -> ClassificationResult? {
        guard let model = model else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<ClassificationResult?, Never>) in
            let request = VNCoreMLRequest(model: model) { request, error in
                guard error == nil,
                      let results = request.results as? [VNClassificationObservation],
                      let top = results.first,
                      top.confidence > 0.1 else {
                    continuation.resume(returning: nil)
                    return
                }

                let allPredictions: [(category: SkillCategory, confidence: Double)] = results
                    .prefix(5)
                    .compactMap { obs in
                        guard let cat = SkillCategory(rawValue: obs.identifier) else { return nil }
                        return (category: cat, confidence: Double(obs.confidence))
                    }

                guard let category = SkillCategory(rawValue: top.identifier) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: ClassificationResult(
                    category: category,
                    confidence: Double(top.confidence),
                    allPredictions: allPredictions
                ))
            }

            request.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    func classify(imageData: Data) async -> ClassificationResult? {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return nil }
        return await classify(cgImage)
    }
}
