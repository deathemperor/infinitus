import Foundation

public struct StatsChunkProgress: Sendable, Equatable {
    public let scannedMB: Int
    public let totalMB: Int
    public let remainingFiles: Int
    public let passCount: Int
    public let stuck: Bool

    public init(scannedMB: Int, totalMB: Int, remainingFiles: Int, passCount: Int, stuck: Bool) {
        self.scannedMB = scannedMB
        self.totalMB = totalMB
        self.remainingFiles = remainingFiles
        self.passCount = passCount
        self.stuck = stuck
    }

    public var progressText: String {
        "scanned \(scannedMB) MB of \(totalMB) MB (\(remainingFiles) files left)"
    }
}

public enum StatsChunkLoop {
    public static let defaultChunkByteBudget: Int = 64 * 1024 * 1024
    public static let defaultMaxPasses: Int = 500

    public struct StepInput: Sendable {
        public let remainingFiles: Int
        public let bytesTotal: Int
        public let bytesRemaining: Int

        public init(remainingFiles: Int, bytesTotal: Int, bytesRemaining: Int) {
            self.remainingFiles = remainingFiles
            self.bytesTotal = bytesTotal
            self.bytesRemaining = bytesRemaining
        }
    }

    public struct State: Sendable {
        public var passCount: Int = 0
        public var cumulativeConsumed: Int = 0
        public var firstBytesTotal: Int? = nil
        public var previousBytesRemaining: Int = Int.max
        public var isDone: Bool = false

        public init() {}

        public mutating func step(input: StepInput, maxPasses: Int = defaultMaxPasses) -> (progress: StatsChunkProgress, stop: Bool) {
            passCount += 1
            if firstBytesTotal == nil { firstBytesTotal = input.bytesTotal }
            let consumedThisPass = input.bytesTotal - input.bytesRemaining
            cumulativeConsumed += max(0, consumedThisPass)
            let stuck = consumedThisPass <= 0 || input.bytesRemaining >= previousBytesRemaining
            previousBytesRemaining = input.bytesRemaining

            let scannedMB = cumulativeConsumed / (1024 * 1024)
            let totalMB = (firstBytesTotal ?? input.bytesTotal) / (1024 * 1024)
            let prog = StatsChunkProgress(
                scannedMB: scannedMB,
                totalMB: totalMB,
                remainingFiles: input.remainingFiles,
                passCount: passCount,
                stuck: stuck
            )

            let stop = input.remainingFiles <= 0 || stuck || passCount >= maxPasses
            if stop { isDone = true }
            return (prog, stop)
        }
    }
}
