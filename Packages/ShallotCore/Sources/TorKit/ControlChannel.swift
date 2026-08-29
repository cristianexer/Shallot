import Foundation
import Tor

/// A minimal async mutual-exclusion primitive.
///
/// Actors are re-entrant across `await`, so actor isolation alone does not stop
/// two control commands from interleaving on one socket. This does.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int = 1) {
        permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A serialised request/response channel to Tor's control port.
///
/// Two things make this worth having rather than using
/// `TorControlClient.getInfo` directly:
///
/// 1. **Data blocks.** Tor answers `GETINFO circuit-status`, `ns/id/…` and
///    `stream-status` with a `250+…` multi-line data block. The high-level
///    client returns only the `key=value` lines and drops the block, which is
///    exactly the part we need for the circuit view.
/// 2. **Serialisation.** One command at a time, so replies can never be
///    attributed to the wrong request.
///
/// No `SETEVENTS` subscription is ever issued on this socket, so nothing
/// asynchronous can arrive mid-reply.
final class ControlChannel: Sendable {
    private let socket: ControlSocket
    private let gate = AsyncSemaphore()

    init(socket: ControlSocket) {
        self.socket = socket
    }

    /// Opens and authenticates a control channel on a loopback port.
    static func connect(port: UInt16, dataDirectory: String) async throws -> ControlChannel {
        let socket = try ControlSocket(host: "127.0.0.1", port: Int(port))
        // Authentication is the one thing routed through the library's client,
        // which knows how to find and format `control_auth_cookie`.
        let client = TorControlClient(socket: socket, dataDirectory: dataDirectory)
        try await client.authenticate()
        return ControlChannel(socket: socket)
    }

    /// Sends one command and returns the full reply, data block included.
    func send(_ command: String) async throws -> ControlReply {
        await gate.wait()
        do {
            let reply = try await socket.sendCommand(command)
            await gate.signal()
            return reply
        } catch {
            await gate.signal()
            throw error
        }
    }

    /// `GETINFO` for a key whose answer arrives as a multi-line data block.
    func getInfoBlock(_ key: String) async throws -> String {
        let reply = try await send("GETINFO \(key)")
        guard reply.isSuccess else {
            throw ControlChannelError.rejected(code: reply.statusCode, message: reply.message)
        }
        // Short answers come back inline as `key=value`; long ones as a block.
        if let data = reply.data, !data.isEmpty { return data }
        return reply.keyValuePairs[key] ?? ""
    }

    /// `GETINFO` for keys whose answers are single `key=value` lines.
    func getInfoValues(_ keys: [String]) async throws -> [String: String] {
        let reply = try await send("GETINFO \(keys.joined(separator: " "))")
        guard reply.isSuccess else {
            throw ControlChannelError.rejected(code: reply.statusCode, message: reply.message)
        }
        return reply.keyValuePairs
    }

    /// Sends a command and throws unless Tor answered with a success code.
    @discardableResult
    func perform(_ command: String) async throws -> ControlReply {
        let reply = try await send(command)
        guard reply.isSuccess else {
            throw ControlChannelError.rejected(code: reply.statusCode, message: reply.message)
        }
        return reply
    }
}

enum ControlChannelError: Error, Sendable, Equatable, CustomStringConvertible {
    case rejected(code: Int, message: String)

    var description: String {
        switch self {
        case .rejected(let code, let message): "Tor refused the command (\(code)): \(message)"
        }
    }
}
