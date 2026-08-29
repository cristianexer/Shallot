import Foundation

/// Fans one source of values out to any number of `AsyncStream` consumers.
///
/// `AsyncStream` is single-consumer, but several parts of the UI want the same
/// bootstrap percentages, bandwidth samples and security events at once. This
/// keeps a continuation per subscriber and drops the ones whose consumer has
/// gone away.
///
/// It holds mutable state and is meant to be owned by an actor, which is what
/// serialises access to it — hence a `struct` with `mutating` members rather
/// than a lock.
public struct AsyncBroadcast<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    public init() {}

    /// Number of live subscribers. Used by tests to assert we do not leak them.
    public var subscriberCount: Int { continuations.count }

    /// Creates a stream for a new subscriber.
    ///
    /// - Parameter initial: Optionally replayed immediately, so a subscriber
    ///   that arrives late still sees current state rather than waiting for the
    ///   next change.
    public mutating func stream(priming initial: Element? = nil) -> AsyncStream<Element> {
        let id = UUID()
        // `.bufferingNewest(32)` keeps a slow consumer from stalling the engine
        // while still tolerating a brief hiccup on the main actor.
        let (stream, continuation) = AsyncStream<Element>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuations[id] = continuation
        if let initial { continuation.yield(initial) }
        return stream
    }

    /// Delivers `value` to every live subscriber and forgets the dead ones.
    public mutating func yield(_ value: Element) {
        var terminated: [UUID] = []
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) { terminated.append(id) }
        }
        for id in terminated { continuations.removeValue(forKey: id) }
    }

    /// Ends every subscriber's stream.
    public mutating func finish() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }
}
