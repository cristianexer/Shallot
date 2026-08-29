import Foundation

/// Everything the Monitor screen shows, aggregated locally.
///
/// Every number here is measured on this device from Tor's own control channel
/// and the browser engine's own callbacks. Nothing is fetched, and nothing is
/// reported anywhere.
@MainActor
public protocol MonitorFeeding: AnyObject {
    var bootstrapProgress: Int { get }
    var circuits: [Circuit] { get }
    /// The circuit the UI shows as "the" path — the most recently built usable one.
    var primaryCircuit: Circuit? { get }
    var streamCount: Int { get }
    /// Newest-first ring buffer of security events.
    var events: [SecurityEvent] { get }
    /// Rolling window of bandwidth samples for the sparkline.
    var bandwidthHistory: [BandwidthSample] { get }
    var latestBandwidth: BandwidthSample? { get }
    /// Host of whatever the active tab is talking to, for the chain's tail node.
    var destinationLabel: String? { get set }

    /// Begins consuming the Tor engine's streams. Safe to call more than once.
    func start()

    /// Appends an event to the log.
    func record(_ event: SecurityEvent)

    /// Pulls circuit status now rather than waiting for the next poll.
    func refreshCircuits() async

    /// Asks Tor for a brand-new set of circuits.
    func requestNewCircuit() async
}
