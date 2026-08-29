import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Finds loopback TCP ports that are free right now.
///
/// Tor needs its SOCKS and control ports named up front — they go on the
/// command line before Tor starts, and the browser's proxy configuration has to
/// point at a known number. Rather than hard-code 9050 and hope, we bind and
/// immediately close candidate ports to confirm they are available.
///
/// This is inherently a check-then-use race, but nothing else on an iOS device
/// is competing for high loopback ports, and Tor fails loudly with a
/// port-in-use error if we lose it.
public enum PortReservation {
    /// Where we start looking. Deliberately away from Tor's well-known 9050 so
    /// a system-wide Orbot on the same device does not collide with us.
    public static let defaultBase: UInt16 = 39_050

    /// Returns `count` free loopback ports, searching upward from `base`.
    ///
    /// - Throws: `Error.exhausted` if nothing is free in the search window,
    ///   which in practice means something is badly wrong with the device.
    public static func reserve(count: Int, from base: UInt16 = defaultBase, window: Int = 400) throws -> [UInt16] {
        precondition(count > 0)
        var found: [UInt16] = []
        var candidate = Int(base)
        let limit = Int(base) + window

        while found.count < count, candidate < limit, candidate <= Int(UInt16.max) {
            let port = UInt16(candidate)
            if isAvailable(port) { found.append(port) }
            candidate += 1
        }

        guard found.count == count else { throw Error.exhausted(needed: count, found: found.count) }
        return found
    }

    /// Whether a TCP listener can currently bind `port` on 127.0.0.1.
    public static func isAvailable(_ port: UInt16) -> Bool {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // Without SO_REUSEADDR a port left in TIME_WAIT would read as busy and
        // we would skip a perfectly usable port on every relaunch.
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
        #else
        return true
        #endif
    }

    public enum Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        case exhausted(needed: Int, found: Int)

        public var description: String {
            switch self {
            case .exhausted(let needed, let found):
                "Could not find \(needed) free local ports for Tor (found \(found))."
            }
        }
    }
}
