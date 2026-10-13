import AppKit
import Foundation
import SSHIntegration
import VMControl
import VMCore

extension AppModel {
    // MARK: SSH

    /// Rewrites the generated SSH configuration from the current library.
    func syncSSHConfiguration() {
        let entries = library.machines.compactMap { machine -> SSHHostEntry? in
            let configuration = machine.configuration
            guard !configuration.ssh.alias.isEmpty, let address = address(for: machine) else { return nil }
            return SSHHostEntry(
                alias: configuration.ssh.alias,
                hostName: address,
                user: configuration.ssh.user.isEmpty ? nil : configuration.ssh.user,
                port: configuration.ssh.port,
                identityFile: configuration.ssh.identityFile
            )
        }
        do {
            try sshWriter.write(entries)
        } catch {
            generalError = VMErrorInfo(title: "Couldn't update the SSH configuration", message: error.localizedDescription)
        }
    }

    /// Adds or removes the `Include` line in `~/.ssh/config`.
    func setSSHIncludeInstalled(_ installed: Bool) {
        do {
            if installed {
                syncSSHConfiguration()
                try sshWriter.installInclude()
            } else {
                try sshWriter.removeInclude()
            }
        } catch {
            generalError = VMErrorInfo(title: "Couldn't change ~/.ssh/config", message: error.localizedDescription)
        }
        isSSHIncludeInstalled = sshWriter.isIncludeInstalled
    }

    /// The command that opens a shell in the guest, or `nil` if the machine has no SSH alias.
    func sshCommand(for machine: VirtualMachine) -> String? {
        let alias = machine.configuration.ssh.alias
        guard !alias.isEmpty, address(for: machine) != nil else { return nil }
        if isSSHIncludeInstalled {
            return "ssh \(alias)"
        }
        // Without the Include line, point ssh at the generated file explicitly.
        return "ssh -F \(Self.shellQuoted(sshWriter.generatedConfigURL.path)) \(alias)"
    }

    func copySSHCommand(for machine: VirtualMachine) {
        guard let command = sshCommand(for: machine) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Opens a terminal window connected to the guest.
    func openTerminal(for machine: VirtualMachine) {
        guard let command = sshCommand(for: machine) else { return }
        let alias = machine.configuration.ssh.alias
        if isSSHIncludeInstalled, let url = URL(string: "ssh://\(alias)") {
            // Goes to the user's default terminal app.
            NSWorkspace.shared.open(url)
            return
        }
        runInTerminal(["exec \(command)"], scriptName: "virtualvm-ssh-\(alias)")
    }

    /// The `virtualvm` tool that ships inside the app, if this build has one.
    var commandLineToolURL: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/virtualvm")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Opens a terminal window on the guest's serial console, which works without a network and before
    /// the guest has finished starting.
    func openSerialConsole(for machine: VirtualMachine) {
        guard let tool = commandLineToolURL else { return }
        var lines: [String] = []
        // The tool has to look where this copy keeps its data. A copy that was told to keep it elsewhere
        // tells the tool as well; one that wasn't makes sure the shell's own settings don't either.
        if let home = ProcessInfo.processInfo.environment[ControlPaths.homeEnvironmentKey], !home.isEmpty {
            lines.append("export \(ControlPaths.homeEnvironmentKey)=\(Self.shellQuoted(home))")
        } else {
            lines.append("unset \(ControlPaths.homeEnvironmentKey)")
        }
        lines.append("exec \(Self.shellQuoted(tool.path)) console \(machine.id.uuidString)")
        runInTerminal(lines, scriptName: "virtualvm-console-\(machine.id.uuidString.prefix(8))")
    }

    /// Runs shell commands in a new window of the user's terminal app.
    private func runInTerminal(_ lines: [String], scriptName: String) {
        let script = FileManager.default.temporaryDirectory.appending(path: "\(scriptName).command")
        do {
            try (["#!/bin/zsh"] + lines).joined(separator: "\n").appending("\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            generalError = VMErrorInfo(title: "Couldn't open Terminal", message: error.localizedDescription)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Sets the clock of a guest that has just been resumed and thinks it is still the moment it was
    /// suspended. A guest with the agent has it set through the agent, by the machine itself. Without
    /// one, this works for Linux guests that let the host sign in and use `sudo`; others are left to
    /// their own time service.
    func correctClock(of machine: VirtualMachine) {
        let configuration = machine.configuration
        guard configuration.os.family == .linux else { return }
        let alias = configuration.ssh.alias
        let configURL = sshWriter.generatedConfigURL
        Task {
            // An agent that is there answers at once, and it is known at once when there is none.
            guard await !machine.agent.waitUntilConnected(timeout: .seconds(2)), !alias.isEmpty else { return }
            await Task.detached(priority: .utility) {
                // The guest's network needs a moment to notice it is back.
                for attempt in 0..<5 {
                    do {
                        try GuestClock.setFromHardwareClock(on: alias, configURL: configURL)
                        return
                    } catch {
                        appLog.debug("Clock sync in “\(alias, privacy: .public)”, attempt \(attempt + 1): \(error.localizedDescription, privacy: .public)")
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                appLog.warning("The clock of the guest at “\(alias, privacy: .public)” was left unsynced after five tries.")
            }.value
        }
    }
}
