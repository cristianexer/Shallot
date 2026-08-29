import Domain
import Foundation

/// Turns Tor's monotonically increasing traffic counters into a rolling window
/// of rates, and keeps the window bounded.
///
/// Split out from the service so the arithmetic — including the awkward cases,
/// like a counter that resets — is unit-tested without a Tor.
public struct BandwidthSampler: Sendable, Equatable {
    /// How many samples the sparkline shows.
    public let windowSize: Int
    public private(set) var samples: [BandwidthSample] = []

    public init(windowSize: Int = 48) {
        precondition(windowSize > 0)
        self.windowSize = windowSize
    }

    public mutating func append(_ sample: BandwidthSample) {
        samples.append(sample)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
    }

    public var latest: BandwidthSample? { samples.last }

    /// The peak rate in the window, used to scale the sparkline.
    ///
    /// Never returns zero: dividing by it is how the chart is drawn.
    public var peakDownRate: Double {
        max(1, samples.map(\.downKilobytesPerSecond).max() ?? 1)
    }

    /// Normalised 0...1 heights for the sparkline.
    public func normalisedHeights() -> [Double] {
        let peak = peakDownRate
        return samples.map { min(1, $0.downKilobytesPerSecond / peak) }
    }

    /// Differences two absolute counter readings into a rate sample.
    ///
    /// A counter that went backwards means Tor restarted its accounting; the
    /// honest answer is zero for that interval rather than a huge negative or a
    /// wrapped positive number.
    public static func difference(
        read: Int,
        written: Int,
        previousRead: Int,
        previousWritten: Int,
        interval: TimeInterval
    ) -> BandwidthSample {
        BandwidthSample(
            downBytes: max(0, read - previousRead),
            upBytes: max(0, written - previousWritten),
            interval: interval
        )
    }
}
