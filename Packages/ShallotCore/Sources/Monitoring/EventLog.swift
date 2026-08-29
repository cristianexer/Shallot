import Domain
import Foundation

/// A bounded, newest-first, in-memory log.
///
/// In memory is not an implementation detail — it is the guarantee. There is no
/// file behind this, nothing is flushed anywhere, and it dies with the process.
public struct EventLog: Sendable, Equatable {
    public let capacity: Int
    public private(set) var events: [SecurityEvent] = []

    public init(capacity: Int = 200) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func append(_ event: SecurityEvent) {
        // Repeating "DNS resolved via Tor · example.org" once per sub-resource
        // would push everything else off the screen within a second.
        if let newest = events.first,
           newest.kind == event.kind,
           newest.message == event.message,
           abs(event.timestamp.timeIntervalSince(newest.timestamp)) < 2 {
            // `abs`, because a negative difference means the event arrived out
            // of order — a clock adjustment, or events built before they were
            // appended — and dropping it as "too soon after" would be wrong in
            // the one direction where the event is genuinely new.
            return
        }
        events.insert(event, at: 0)
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
    }

    public mutating func clear() {
        events.removeAll()
    }

    /// The most recent `count` events, for the terminal view.
    public func recent(_ count: Int) -> [SecurityEvent] {
        Array(events.prefix(count))
    }
}
