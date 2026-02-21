import Foundation
import Vision
import UIKit
import CoreImage

// MARK: - Face Memory Service
/// Detects faces, crops them, computes perceptual hashes for matching.
/// Uses face landmarks (eye/nose/mouth positions) as additional feature vectors.
/// All data stored locally as JSON in the app's Documents directory.
class FaceMemoryService: ObservableObject {
    
    @Published var knownFaces: [SavedFace] = []
    
    private let storageURL: URL
    private let matchThreshold: Float = 0.80 // Higher = stricter (0-1 scale)
    private let hashSize = 16 // 16x16 perceptual hash
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("lookout_faces.json")
        loadFaces()
    }
    
    // MARK: - Detect & Match
    
    /// Detect faces in an image and return matches against known faces.
    func detectAndMatch(imageData: Data) async -> [FaceMatch] {
        guard let uiImage = UIImage(data: imageData), let cgImage = uiImage.cgImage else { return [] }
        
        let faceObservations = await detectFacesWithLandmarks(in: cgImage)
        guard !faceObservations.isEmpty else { return [] }
        
        var matches: [FaceMatch] = []
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        
        for face in faceObservations {
            // Ignore very small detections to reduce false matches.
            let area = face.boundingBox.width * face.boundingBox.height
            if area < 0.012 { continue }
            
            let features = extractFeatures(face: face, cgImage: cgImage, imageSize: imageSize)
            
            if let features = features {
                if let match = findBestMatch(features: features) {
                    matches.append(FaceMatch(
                        name: match.name,
                        confidence: match.confidence,
                        boundingBox: face.boundingBox,
                        isNew: false
                    ))
                } else {
                    matches.append(FaceMatch(
                        name: nil,
                        confidence: 0,
                        boundingBox: face.boundingBox,
                        isNew: true
                    ))
                }
            }
        }
        
        return matches
    }
    
    // MARK: - Save New Face
    
    func saveFace(name: String, imageData: Data, relationship: String = "") async -> Bool {
        guard let uiImage = UIImage(data: imageData), let cgImage = uiImage.cgImage else { return false }
        
        let faceObservations = await detectFacesWithLandmarks(in: cgImage)
        guard let face = largestFace(in: faceObservations) else { return false }
        
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard let features = extractFeatures(face: face, cgImage: cgImage, imageSize: imageSize) else { return false }
        
        if let idx = knownFaces.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            knownFaces[idx].featureSets.append(features)
            if knownFaces[idx].featureSets.count > 10 {
                knownFaces[idx].featureSets.removeFirst()
            }
            knownFaces[idx].lastSeen = Date()
        } else {
            let newFace = SavedFace(
                name: name,
                relationship: relationship,
                featureSets: [features],
                firstSeen: Date(),
                lastSeen: Date(),
                timesSeen: 1
            )
            knownFaces.append(newFace)
        }
        
        saveFacesToDisk()
        return true
    }
    
    func markSeen(name: String) {
        if let idx = knownFaces.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            knownFaces[idx].lastSeen = Date()
            knownFaces[idx].timesSeen += 1
            saveFacesToDisk()
        }
    }
    
    func removeFace(name: String) {
        knownFaces.removeAll { $0.name.lowercased() == name.lowercased() }
        saveFacesToDisk()
    }
    
    func removeAllFaces() {
        knownFaces = []
        saveFacesToDisk()
    }
    
    // MARK: - Vision Face Detection (Landmarks)
    
    private func detectFacesWithLandmarks(in cgImage: CGImage) async -> [VNFaceObservation] {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceLandmarksRequest { request, error in
                if let error = error {
                    #if DEBUG
                    print("⚠️ Face detection error: \(error)")
                    #endif
                    continuation.resume(returning: [])
                    return
                }
                let faces = request.results as? [VNFaceObservation] ?? []
                continuation.resume(returning: faces)
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
    
    // MARK: - Feature Extraction
    
    /// Combines perceptual hash of cropped face + landmark geometry.
    private func extractFeatures(face: VNFaceObservation, cgImage: CGImage, imageSize: CGSize) -> FaceFeatures? {
        let bbox = face.boundingBox
        // Vision uses bottom-left origin, CGImage uses top-left
        let x = bbox.origin.x * imageSize.width
        let y = (1 - bbox.origin.y - bbox.height) * imageSize.height
        let w = bbox.width * imageSize.width
        let h = bbox.height * imageSize.height
        
        // Padding around face
        let padding: CGFloat = 0.2
        let px = max(0, x - w * padding)
        let py = max(0, y - h * padding)
        let pw = min(imageSize.width - px, w * (1 + 2 * padding))
        let ph = min(imageSize.height - py, h * (1 + 2 * padding))
        
        let cropRect = CGRect(x: px, y: py, width: pw, height: ph)
        guard let croppedFace = cgImage.cropping(to: cropRect) else { return nil }
        
        // Vision feature print (embedding) for robust identity matching.
        let featurePrint = computeImageFeaturePrint(cgImage: croppedFace)
        
        // Perceptual hash
        let hash = computePerceptualHash(cgImage: croppedFace)
        
        // Landmark geometry
        var landmarkVector: [Float] = []
        
        if let landmarks = face.landmarks {
            let regions: [VNFaceLandmarkRegion2D?] = [
                landmarks.leftEye,
                landmarks.rightEye,
                landmarks.nose,
                landmarks.noseCrest,
                landmarks.outerLips,
                landmarks.leftEyebrow,
                landmarks.rightEyebrow
            ]
            
            for region in regions {
                if let points = region?.normalizedPoints, !points.isEmpty {
                    let cx = points.map { Float($0.x) }.reduce(0, +) / Float(points.count)
                    let cy = points.map { Float($0.y) }.reduce(0, +) / Float(points.count)
                    landmarkVector.append(cx)
                    landmarkVector.append(cy)
                } else {
                    landmarkVector.append(0)
                    landmarkVector.append(0)
                }
            }
            
            // Inter-feature distances
            if let leftEye = landmarks.leftEye?.normalizedPoints.first,
               let rightEye = landmarks.rightEye?.normalizedPoints.first {
                let eyeDist = Float(hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y))
                landmarkVector.append(eyeDist)
            }
            
            if let nose = landmarks.nose?.normalizedPoints.first,
               let mouth = landmarks.outerLips?.normalizedPoints.first {
                let noseToMouth = Float(hypot(mouth.x - nose.x, mouth.y - nose.y))
                landmarkVector.append(noseToMouth)
            }
        }
        
        return FaceFeatures(
            perceptualHash: hash,
            landmarkVector: landmarkVector,
            featurePrint: featurePrint.isEmpty ? nil : featurePrint,
            faceWidth: Float(bbox.width),
            faceHeight: Float(bbox.height)
        )
    }
    
    private func computeImageFeaturePrint(cgImage: CGImage) -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else { return [] }
            
            switch observation.elementType {
            case .float:
                let count = min(Int(observation.elementCount), observation.data.count / MemoryLayout<Float>.size)
                guard count > 0 else { return [] }
                let values: [Float] = observation.data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: Float.self).baseAddress else { return [] }
                    return Array(UnsafeBufferPointer(start: base, count: count))
                }
                return normalizeVector(values)
            case .double:
                let count = min(Int(observation.elementCount), observation.data.count / MemoryLayout<Double>.size)
                guard count > 0 else { return [] }
                let values: [Float] = observation.data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: Double.self).baseAddress else { return [] }
                    return Array(UnsafeBufferPointer(start: base, count: count)).map { Float($0) }
                }
                return normalizeVector(values)
            default:
                // Unknown element type fallback: use normalized byte vector.
                let values = observation.data.map { Float($0) / 255.0 }
                return normalizeVector(values)
            }
        } catch {
            return []
        }
    }
    
    private func normalizeVector(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        var mag: Float = 0
        for v in values { mag += v * v }
        let norm = sqrt(mag)
        guard norm > 0 else { return values }
        return values.map { $0 / norm }
    }
    
    // MARK: - Perceptual Hash
    
    /// Resize to small grayscale → compare pixels to average → binary hash.
    private func computePerceptualHash(cgImage: CGImage) -> [UInt8] {
        let size = hashSize
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return []
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        
        guard let data = context.data else { return [] }
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size)
        
        var sum: Int = 0
        for i in 0..<(size * size) {
            sum += Int(pixels[i])
        }
        let average = UInt8(sum / (size * size))
        
        var hash: [UInt8] = []
        for i in 0..<(size * size) {
            hash.append(pixels[i] > average ? 1 : 0)
        }
        
        return hash
    }
    
    // MARK: - Matching
    
    private func findBestMatch(features: FaceFeatures) -> (name: String, confidence: Float)? {
        guard !features.perceptualHash.isEmpty else { return nil }
        
        var bestName: String?
        var bestScore: Float = 0
        
        for face in knownFaces {
            for saved in face.featureSets {
                let score = compareFaces(a: features, b: saved)
                if score > bestScore {
                    bestScore = score
                    bestName = face.name
                }
            }
        }
        
        if let name = bestName, bestScore >= matchThreshold {
            return (name, bestScore)
        }
        
        return nil
    }
    
    /// Compare two face feature sets. Returns similarity 0-1.
    private func compareFaces(a: FaceFeatures, b: FaceFeatures) -> Float {
        var totalScore: Float = 0
        var weights: Float = 0
        let hasFeaturePrint: Bool = {
            guard let va = a.featurePrint, let vb = b.featurePrint else { return false }
            return !va.isEmpty && va.count == vb.count
        }()
        
        // Primary signal: Vision feature print embedding similarity.
        if hasFeaturePrint, let va = a.featurePrint, let vb = b.featurePrint {
            let cosine = cosineSimilarity(va, vb)
            let fpScore = max(0, min(1, (cosine + 1) / 2))
            totalScore += fpScore * 0.75
            weights += 0.75
        }
        
        // Perceptual hash similarity (Hamming distance)
        if !a.perceptualHash.isEmpty && !b.perceptualHash.isEmpty &&
           a.perceptualHash.count == b.perceptualHash.count {
            var matching = 0
            for i in 0..<a.perceptualHash.count {
                if a.perceptualHash[i] == b.perceptualHash[i] {
                    matching += 1
                }
            }
            let hashSim = Float(matching) / Float(a.perceptualHash.count)
            let hashWeight: Float = hasFeaturePrint ? 0.15 : 0.6
            totalScore += hashSim * hashWeight
            weights += hashWeight
        }
        
        // Landmark geometry similarity (cosine)
        if !a.landmarkVector.isEmpty && !b.landmarkVector.isEmpty &&
           a.landmarkVector.count == b.landmarkVector.count {
            let cosine = cosineSimilarity(a.landmarkVector, b.landmarkVector)
            let landmarkScore = (cosine + 1) / 2
            let landmarkWeight: Float = hasFeaturePrint ? 0.10 : 0.4
            totalScore += landmarkScore * landmarkWeight
            weights += landmarkWeight
        }
        
        return weights > 0 ? totalScore / weights : 0
    }
    
    private func largestFace(in faces: [VNFaceObservation]) -> VNFaceObservation? {
        faces.max { (lhs, rhs) in
            (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
        }
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
    
    // MARK: - Persistence
    
    private func loadFaces() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            knownFaces = try JSONDecoder().decode([SavedFace].self, from: data)
        } catch {
            #if DEBUG
            print("⚠️ Failed to load faces: \(error)")
            #endif
        }
    }
    
    private func saveFacesToDisk() {
        do {
            let data = try JSONEncoder().encode(knownFaces)
            try data.write(to: storageURL)
        } catch {
            #if DEBUG
            print("⚠️ Failed to save faces: \(error)")
            #endif
        }
    }
    
    var contextSummary: String {
        guard !knownFaces.isEmpty else { return "" }
        let people = knownFaces.map { face in
            var desc = face.name
            if !face.relationship.isEmpty { desc += " (\(face.relationship))" }
            return desc
        }
        return "Known people: \(people.joined(separator: ", "))"
    }
}

// MARK: - Models

struct FaceFeatures: Codable {
    let perceptualHash: [UInt8]
    let landmarkVector: [Float]
    let featurePrint: [Float]?
    let faceWidth: Float
    let faceHeight: Float
}

struct SavedFace: Codable, Identifiable {
    let id: UUID
    var name: String
    var relationship: String
    var featureSets: [FaceFeatures]
    var firstSeen: Date
    var lastSeen: Date
    var timesSeen: Int
    
    var sampleCount: Int { featureSets.count }
    
    init(name: String, relationship: String = "", featureSets: [FaceFeatures], firstSeen: Date, lastSeen: Date, timesSeen: Int) {
        self.id = UUID()
        self.name = name
        self.relationship = relationship
        self.featureSets = featureSets
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.timesSeen = timesSeen
    }
}

struct FaceMatch {
    let name: String?
    let confidence: Float
    let boundingBox: CGRect
    let isNew: Bool
}
