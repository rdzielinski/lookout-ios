import Foundation
import UIKit

// MARK: - Frame Buffer Service
/// Keeps a rolling buffer of recent camera frames for the "What did I just see?" replay feature.
/// Stores compressed JPEG data to limit memory usage (~30 seconds at configurable interval).
class FrameBufferService {
    static let shared = FrameBufferService()

    struct BufferedFrame {
        let imageData: Data
        let timestamp: Date
    }

    /// Rolling buffer of recent frames
    private(set) var frames: [BufferedFrame] = []

    /// How long to keep frames (seconds)
    var bufferDuration: TimeInterval = 30

    /// Maximum number of frames to keep
    var maxFrames: Int = 15

    private init() {}

    /// Add a new frame to the buffer. Automatically evicts old frames.
    func addFrame(imageData: Data) {
        let frame = BufferedFrame(imageData: imageData, timestamp: Date())
        frames.append(frame)

        // Evict frames older than bufferDuration
        let cutoff = Date().addingTimeInterval(-bufferDuration)
        frames.removeAll { $0.timestamp < cutoff }

        // Also cap at maxFrames
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
    }

    /// Add a frame from a UIImage (compresses to JPEG)
    func addFrame(image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.4) else { return }
        addFrame(imageData: data)
    }

    /// Get the most recent frame (for "what did I just see?")
    func mostRecentFrame() -> BufferedFrame? {
        frames.last
    }

    /// Get a frame from approximately N seconds ago
    func frameFromSecondsAgo(_ seconds: TimeInterval) -> BufferedFrame? {
        let targetTime = Date().addingTimeInterval(-seconds)
        // Find the frame closest to the target time
        return frames.min(by: { abs($0.timestamp.timeIntervalSince(targetTime)) < abs($1.timestamp.timeIntervalSince(targetTime)) })
    }

    /// Clear all buffered frames
    func clear() {
        frames.removeAll()
    }

    /// Current buffer size in approximate MB
    var bufferSizeMB: Double {
        Double(frames.reduce(0) { $0 + $1.imageData.count }) / (1024 * 1024)
    }
}
