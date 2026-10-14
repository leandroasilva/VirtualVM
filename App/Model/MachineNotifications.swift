import Foundation
import UserNotifications
import VMCore

/// System notifications about machines. The app lives in the menu bar and never raises alerts of its
/// own (see ``PendingMessage``), which leaves a creation that runs for minutes invisible until someone
/// opens the panel. A notification is the one message that can reach the user meanwhile.
enum MachineNotifications {
    /// Whether `UNUserNotificationCenter` may be touched at all: outside a real app bundle — a bare
    /// `swift run` binary for one — asking for it raises an Objective-C exception nothing can catch.
    private static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks the user, once, whether VirtualVM may notify. Safe to call on every launch; macOS shows the
    /// prompt the first time only.
    static func requestAuthorization() {
        guard isBundled else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    static func post(title: String, body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func creationFinished(_ machine: VirtualMachine) {
        post(title: "“\(machine.name)” is ready", body: "The virtual machine finished being created.")
    }

    static func creationFailed(name: String, reason: String) {
        post(title: "“\(name)” couldn't be created", body: reason)
    }
}
