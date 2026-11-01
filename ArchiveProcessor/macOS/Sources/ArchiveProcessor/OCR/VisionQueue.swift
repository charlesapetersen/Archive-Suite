import Foundation

/// Runs synchronous Vision work off Swift's cooperative thread pool (W40.fix-processor-rotation-deadlock).
///
/// `VNImageRequestHandler.perform` blocks its thread until Vision's own work finishes, and part of that work
/// (TextRecognition, the Neural Engine callbacks) runs on the cooperative pool itself. Called from tasks, enough
/// blocked passes take every pool thread and nothing is left to finish them: a Live Capture segment sat at 0% CPU
/// forever with eleven pool threads parked in `RotationDetector.score`. Work submitted here runs on this queue's own
/// threads, at most `width` at a time, while the awaiting task holds no thread.
final class VisionQueue: Sendable {
    private let queue: OperationQueue

    init(name: String, width: Int) {
        let q = OperationQueue()
        q.name = name
        q.maxConcurrentOperationCount = max(1, width)
        q.qualityOfService = .userInitiated
        queue = q
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { continuation.resume(with: Result { try body() }) }
        }
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: body()) }
        }
    }
}
