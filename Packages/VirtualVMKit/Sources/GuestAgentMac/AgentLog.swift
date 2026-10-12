import Foundation
import os

/// What the agent has to say goes to the system's log: `log show --predicate 'subsystem == "com.virtualvm.agent"'`.
/// Nothing that was copied is ever written there.
enum AgentLog {
    private static let logger = Logger(subsystem: "com.virtualvm.agent", category: "agent")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
