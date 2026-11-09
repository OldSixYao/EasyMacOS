import CoreGraphics
import Foundation

/// One display decode at a time, off the main actor. Calls remain in the requesting task:
/// canceled views queued behind a decode are skipped before starting ImageIO work.
public actor DisplayImageDecoder {
    public static let shared = DisplayImageDecoder()
    private let decodeImage: @Sendable (Data, Int) throws -> CGImage

    public init() {
        decodeImage = { data, size in
            try ImageProcessor.decodeForDisplay(data, maximumPixelSize: size)
        }
    }

    init(decodeImage: @escaping @Sendable (Data, Int) throws -> CGImage) {
        self.decodeImage = decodeImage
    }

    public func decode(_ data: Data, maximumPixelSize: Int) async throws -> CGImage {
        let pixels = max(1, min(8192, maximumPixelSize))
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: pixels * pixels * 4, operation: {
            try decodeAdmitted(data, maximumPixelSize: maximumPixelSize)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: pixels * pixels * 4, priority: .display) {
            try await self.decodeAdmitted(data, maximumPixelSize: maximumPixelSize)
        }
    }
    private func decodeAdmitted(_ data: Data, maximumPixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = try decodeImage(data, maximumPixelSize)
            // A synchronous ImageIO call cannot be interrupted; discard its result on cancellation.
            try Task.checkCancellation()
            return image
        }
    }
}
