import Foundation
import GuestAgentMac

// virtualvm-agent: the VirtualVM guest agent for macOS guests. It runs inside a virtual machine, not on the
// Mac that runs VirtualVM, and is put there by the guest tools installer.

exit(AgentCommand.run(Array(CommandLine.arguments.dropFirst())))
