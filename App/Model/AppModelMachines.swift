import AppKit
import SSHIntegration
import VMCore

extension AppModel {
    // MARK: Machines

    /// An SSH alias derived from `name` that no other machine uses.
    func uniqueAlias(for name: String) -> String {
        let taken = Set(library.machines.map(\.configuration.ssh.alias))
        return SSHAlias.unique(SSHAlias.slug(from: name), avoiding: taken)
    }

    /// Whether a machine or an in-progress creation already uses `name`.
    func isNameTaken(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return library.machines.contains { $0.name.lowercased() == lowered }
            || creations.contains { $0.name.lowercased() == lowered }
    }

    /// Asks the guest to shut down, or to restart once it has.
    ///
    /// A guest with the guest tools just does it. macOS without them answers with a dialog on its own
    /// screen, so the machine's window is brought up for someone to see it. Without an answer the machine
    /// simply stays running.
    ///
    /// - Parameter activatingApp: Also bring the app forward for that dialog, for a request that was
    ///   made by someone at this Mac rather than by the command-line tool.
    @discardableResult
    func shutDown(_ machine: VirtualMachine, thenRestart: Bool = false, activatingApp: Bool = false) async -> ShutdownRequest? {
        let request = thenRestart ? await machine.restart() : await machine.shutDown()
        if request == .powerButton, machine.configuration.asksBeforeShuttingDown {
            windows.showMachine(machine.id, activatingApp: activatingApp)
        }
        return request
    }

    /// The user has said how to quit with machines running. From here until the app is gone nothing
    /// starts and the command-line tool is turned down: a machine that came up now, or a snapshot that
    /// began, would be cut off by the quit.
    func closeDown() {
        isClosingDown = true
        library.allowsStarting = false
    }

    /// Shuts down the machines that are up because the app is about to quit, and returns when none is
    /// left running. Call ``closeDown()`` first.
    ///
    /// Running guests with the guest tools are asked through them and shut down properly; they get a
    /// moment for it, and so do guests that were already on their way down. Everything else is stopped
    /// outright: there is no telling how long another guest would take, or whether it would put up a
    /// question that nobody is going to answer.
    func shutDownForQuit(_ machines: [VirtualMachine], patience: Duration = .seconds(45)) async {
        for machine in machines where machine.state == .running && machine.agent.isConnected {
            await machine.shutDown()
        }
        // A macOS guest that was asked with the power button is waiting for an answer on its screen,
        // not shutting down. Its agent, had it one, would have been asked instead.
        func isOnItsWayDown(_ machine: VirtualMachine) -> Bool {
            machine.state == .stopping && (machine.agent.isConnected || !machine.configuration.asksBeforeShuttingDown)
        }
        let deadline = ContinuousClock.now + patience
        while machines.contains(where: isOnItsWayDown), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for machine in machines where machine.state.isActive {
            await machine.forceStop()
        }
    }

    func delete(_ machine: VirtualMachine) {
        let alias = machine.configuration.ssh.alias
        do {
            try library.remove(machine, movingToTrash: true)
            if !alias.isEmpty {
                sshWriter.forgetHostKey(for: alias)
            }
        } catch {
            generalError = VMErrorInfo(title: "Couldn't delete “\(machine.name)”", message: error.localizedDescription)
        }
    }

    func revealInFinder(_ machine: VirtualMachine) {
        NSWorkspace.shared.activateFileViewerSelecting([machine.bundle.url])
    }

    var activeMachines: [VirtualMachine] {
        library.machines.filter(\.state.isActive)
    }

    /// Whether a snapshot, a copy or a resize is under way on any machine.
    var isWorkingOnMachineFiles: Bool {
        library.machines.contains { $0.activity != nil }
    }

    /// Returns once no machine's files are being worked on. That work is short, and stopping the app in
    /// the middle of it could leave a machine half saved.
    func waitForWorkOnMachineFiles() async {
        while isWorkingOnMachineFiles {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Creations that are still working (not failed and waiting to be dismissed).
    var creationsInProgress: [MachineCreation] {
        creations.filter { $0.errorMessage == nil }
    }
}
