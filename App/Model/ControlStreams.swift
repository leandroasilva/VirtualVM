import AppKit
import Installers
import VMControl
import VMCore
import VZEngine
extension AppModel {
    // MARK: Streams

    /// Answers a request that turns its connection into a byte stream. With a yes comes what serves the
    /// stream once the answer has gone out.
    func openStream(_ request: ControlRequest) async -> (response: ControlResponse, stream: ControlServer.Stream?) {
        guard !isQuittingUnattended, !isClosingDown else { return (.failure("\(AppIdentity.current.name) is quitting."), nil) }
        guard let identifier = request.machine else { return (.failure("Missing machine name."), nil) }
        guard let machine = findMachine(identifier) else { return (notFound(identifier), nil) }
        switch request.command {
        case .console:
            let (console, name) = (machine.console, machine.name)
            return (success(machine), { connection in await Self.serveConsole(console, name: name, connection: connection) })
        case .vsock:
            guard let port = request.port, port > 0 else { return (.failure("Missing port."), nil) }
            // The agent serves one connection, the app's. Another one would take its place.
            guard port != GuestAgent.port else {
                return (.failure("Port \(port) is the line between VirtualVM and the guest tools, and not for anything else."), nil)
            }
            do {
                let guest = try await machine.connectToGuest(port: port)
                return (success(machine), { connection in
                    await ByteRelay.run(between: connection, and: guest.fileDescriptor)
                    try? guest.close()
                })
            } catch let error as VMError {
                return (.failure(error.localizedDescription), nil)
            } catch {
                return (.failure("Nothing in “\(machine.name)” answers on port \(port) of its socket device. (\(error.localizedDescription))"), nil)
            }
        default:
            return (.failure("This command doesn't open a stream."), nil)
        }
    }

    /// Connects a `virtualvm console` session to a machine's serial console and returns when the tool hangs
    /// up. Like a cable, the session survives the machine being stopped and started.
    private nonisolated static func serveConsole(_ console: SerialConsole, name: String, connection: Int32) async {
        let writer = ConsoleClientWriter(descriptor: connection)
        let token = console.addListener { event in
            switch event {
            case .output(let data):
                writer.write(data)
            case .connectionChanged(let isConnected):
                writer.write(Data("\r\n[“\(name)” \(isConnected ? "is starting" : "has stopped")]\r\n".utf8))
            }
        }
        if !console.isConnected {
            writer.write(Data("[“\(name)” isn't running. The console comes to life when it starts.]\r\n".utf8))
        }

        // What is typed goes to the guest. This holds a thread, not the main actor, until the tool leaves.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(connection, &buffer, buffer.count)
                    if count > 0 {
                        console.send(Data(buffer[0..<count]))
                    } else if count == 0 || errno != EINTR {
                        break
                    }
                }
                continuation.resume()
            }
        }
        console.removeListener(token)
        // The connection is closed after this returns; nothing may be written to its number any more.
        writer.close()
    }
}

/// Writes console output to one `virtualvm console` session without ever holding up the guest: the writes
/// queue up behind a slow terminal instead. A terminal that has stopped taking output altogether (a
/// tool that was stopped or sent to the background) is cut off once too much has piled up.
private nonisolated final class ConsoleClientWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "VirtualVM console session")
    private let lock = NSLock()
    /// Bytes handed to ``write(_:)`` that haven't reached the terminal yet.
    private var backlog = 0
    /// Set when nothing more may be done with the descriptor, either way.
    private var isFinished = false

    static let backlogLimit = 4 << 20

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func write(_ data: Data) {
        let isAccepted = lock.withLock {
            guard !isFinished else { return false }
            backlog += data.count
            if backlog > Self.backlogLimit {
                isFinished = true
                // Ends the read that waits for the terminal's typing, and with it the session.
                shutdown(descriptor, SHUT_RDWR)
                return false
            }
            return true
        }
        guard isAccepted else { return }
        queue.async { [self] in
            defer { lock.withLock { backlog -= data.count } }
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard !lock.withLock({ isFinished }) else { return }
                    let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if errno != EINTR {
                        return
                    }
                }
            }
        }
    }

    /// Returns once nothing more will be written, so that the descriptor can be closed.
    func close() {
        lock.withLock { isFinished = true }
        queue.sync {}
    }
}
