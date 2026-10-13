import AppKit
import Installers
import VMControl
import VMCore
import VZEngine
/// Handles requests from the `virtualvm` command-line tool.
extension AppModel {
    func handle(_ request: ControlRequest) async -> ControlResponse {
        guard !isQuittingUnattended, !isClosingDown else { return .failure("\(AppIdentity.current.name) is quitting.") }
        switch request.command {
        case .list:
            if let identifier = request.machine {
                guard let machine = findMachine(identifier) else { return notFound(identifier) }
                return success(machine)
            }
            return ControlResponse(ok: true, machines: library.machines.map { summary(of: $0) })
        case .info:
            guard let identifier = request.machine else { return .failure("Missing machine name.") }
            guard let machine = findMachine(identifier) else { return notFound(identifier) }
            return details(machine)
        case .create:
            guard let parameters = request.create else { return .failure("Missing creation parameters.") }
            return await createMachine(parameters)
        case .usbList:
            guard usb.availability == .available else {
                return .failure(USBPassthrough.Failure.unavailable(usb.availability).localizedDescription)
            }
            let devices = usb.devices.map { summary(of: $0) }
            return ControlResponse(ok: true, note: devices.isEmpty ? USBDevicesHint.howToGiveOne : nil, usbDevices: devices)
        case .quit:
            // Quitting from the command line never puts up the dialog that asks what to do with machines.
            guard activeMachines.isEmpty else {
                return .failure("Stop or suspend the running virtual machines first.")
            }
            let creating = creationsInProgress
            guard creating.isEmpty || request.cancelsCreations == true else {
                let subject = creating.count == 1 ? "“\(creating[0].name)” is" : "\(creating.count) virtual machines are"
                return .failure("\(subject) still being created. To quit anyway, use `virtualvm quit --cancel-creations`: a download carries on where it stopped the next time, an installation starts over.")
            }
            guard !isWorkingOnMachineFiles else {
                return .failure("A virtual machine is busy with a snapshot, a copy or a resize. Try again in a moment.")
            }
            quitUnattended()
            return ControlResponse(ok: true)
        default:
            break
        }

        guard let identifier = request.machine else { return .failure("Missing machine name.") }
        guard let machine = findMachine(identifier) else { return notFound(identifier) }
        machine.lastError = nil

        switch request.command {
        case .start:
            await machine.start()
        case .stop:
            let request = await shutDown(machine)
            // The machine goes back to running when the guest doesn't act on the request.
            _ = await waitForState(of: machine, timeout: .seconds(90), where: { $0 != .stopping })
            guard machine.state == .stopped else {
                if request == .powerButton, machine.configuration.asksBeforeShuttingDown {
                    return .failure("“\(machine.name)” asks for confirmation on its screen before it shuts down, and nobody answered. Answer it in the machine's window, or use force-stop to stop it immediately.\(guestToolsHint(for: machine))")
                }
                return .failure("“\(machine.name)” didn't shut down in time. Use force-stop to stop it immediately.")
            }
        case .forceStop:
            await machine.forceStop()
        case .suspend:
            await machine.suspend()
        case .pause:
            await machine.pause()
        case .resume:
            await machine.resume()
        case .restart:
            guard machine.state == .running else { return .failure("“\(machine.name)” isn't running.") }
            let runs = machine.startCount
            let request = await shutDown(machine, thenRestart: true)
            // Wait for the guest to go down and come back up. Its state alone doesn't say: a guest that
            // shuts down at once is running again between two looks.
            let deadline = ContinuousClock.now + .seconds(150)
            while machine.startCount == runs || machine.state != .running {
                if machine.startCount == runs, machine.state == .running {
                    // Still the same run: the guest was asked and has let the request pass.
                    if request == .powerButton, machine.configuration.asksBeforeShuttingDown {
                        return .failure("“\(machine.name)” asks for confirmation on its screen before it restarts, and nobody answered. Answer it in the machine's window.\(guestToolsHint(for: machine))")
                    }
                    return .failure("“\(machine.name)” didn't shut down in time, so it wasn't restarted.")
                }
                // It failed to start again, which the error says better than this could.
                guard machine.lastError == nil else { break }
                if machine.state == .stopped, !machine.isRestartPending {
                    // The guest couldn't be asked and was stopped outright, which is no restart.
                    return .failure("“\(machine.name)” was stopped and didn't start again.")
                }
                guard ContinuousClock.now < deadline else {
                    return .failure("“\(machine.name)” didn't come back up in time.")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        case .open:
            guard windows.showMachine(machine.id, activatingApp: false) else {
                return .failure("\(AppIdentity.current.name) has only just opened and can't show a window yet. Try again in a moment.")
            }
        case .delete:
            guard !machine.state.isActive else { return .failure("Stop “\(machine.name)” before deleting it.") }
            let summary = summary(of: machine)
            delete(machine)
            if let error = generalError {
                generalError = nil
                return .failure(error.message)
            }
            return ControlResponse(ok: true, machines: [summary])
        case .share:
            guard let share = request.share else { return .failure("Missing folder path.") }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: share.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure("“\(share.path)” isn't a folder.")
            }
            changeConfiguration(of: machine) { configuration in
                if let index = configuration.sharedFolders.firstIndex(where: { $0.path == share.path }) {
                    configuration.sharedFolders[index].readOnly = share.readOnly
                } else {
                    let name = URL(fileURLWithPath: share.path).lastPathComponent
                    configuration.sharedFolders.append(SharedFolder(name: name, path: share.path, readOnly: share.readOnly))
                }
            }
        case .unshare:
            guard let share = request.share else { return .failure("Missing folder path.") }
            guard machine.configuration.sharedFolders.contains(where: { $0.path == share.path }) else {
                return .failure("“\(share.path)” isn't shared with “\(machine.name)”.")
            }
            changeConfiguration(of: machine) { $0.sharedFolders.removeAll { $0.path == share.path } }
        case .attach:
            guard let drive = request.drive else { return .failure("Missing disk image.") }
            do {
                try await machine.attachImage(RemovableImage(url: URL(fileURLWithPath: drive.path), readOnly: drive.readOnly))
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .eject:
            guard let drive = request.drive else { return .failure("Missing disk image.") }
            let images = machine.configuration.removableImages
            // A full path names one image; a bare file name is enough when only one image has it.
            let matches = drive.path.contains("/")
                ? images.filter { $0.path == drive.path }
                : images.filter { $0.name == drive.path }
            guard let image = matches.first else {
                return .failure("“\(drive.path)” isn't attached to “\(machine.name)”.")
            }
            guard matches.count == 1 else {
                return .failure("More than one attached image is called “\(drive.path)”. Give its full path.")
            }
            do {
                try await machine.ejectImage(image.id)
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .forward:
            guard let parameters = request.forward else { return .failure("Missing port.") }
            let forward = PortForward(
                transport: parameters.udp ? .udp : .tcp, hostPort: parameters.hostPort,
                guestPort: parameters.guestPort ?? parameters.hostPort, allowsOtherDevices: parameters.allowsOtherDevices
            )
            do {
                try addPortForward(forward, to: machine)
            } catch {
                return .failure(error.localizedDescription)
            }
            // For a running machine the port is opened right away; say so if that didn't work.
            if machine.state == .running {
                let deadline = ContinuousClock.now + .seconds(3)
                while portForwarder.statuses[forward.id] ?? .starting == .starting, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if case .failed(let reason) = portForwarder.statuses[forward.id] {
                    return .failure("The forward was added, but the port isn't open: \(reason) VirtualVM keeps trying while “\(machine.name)” runs.")
                }
            }
            return details(machine)
        case .unforward:
            guard let parameters = request.forward else { return .failure("Missing port.") }
            let transport: PortForward.TransportProtocol = parameters.udp ? .udp : .tcp
            let forwards = machine.configuration.networkInterfaces.flatMap(\.portForwards)
            guard let forward = forwards.first(where: { $0.hostPort == parameters.hostPort && $0.transport == transport }) else {
                return .failure("“\(machine.name)” doesn't forward \(transport.rawValue.uppercased()) port \(parameters.hostPort).")
            }
            do {
                try removePortForward(forward.id, from: machine)
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .plug, .unplug:
            guard !machine.configuration.networkInterfaces.isEmpty else {
                return .failure("“\(machine.name)” has no network interface.")
            }
            // In between states the change would be written down and not reach the guest.
            guard !machine.state.isTransitioning else {
                return .failure("“\(machine.name)” is busy starting up or shutting down. Try again in a moment.")
            }
            changeConfiguration(of: machine) { $0.networkInterfaces[0].isConnected = request.command == .plug }
        case .installTools:
            do {
                if request.usesDisc == true {
                    let disc = try await attachGuestToolsDisc(to: machine)
                    var response = details(machine)
                    let alias = machine.configuration.ssh.alias
                    response.note = """
                        The guest tools disc is plugged into “\(machine.name)”. To install from it, run this in the guest:

                            \(guestToolsInstallCommand(for: machine))

                        Afterwards, eject the disc: virtualvm eject \(alias.isEmpty ? machine.id.uuidString : alias) "\(disc.name)"
                        """
                    return response
                }
                try await installGuestTools(on: machine, password: request.password)
            } catch let error as ProcessRunner.Failure {
                if let complaint = LinuxGuestAgent.installerComplaint(in: error) {
                    // The installer ran and gave up; from the disc it would give up the same way.
                    return .failure("The guest tools couldn't be installed in “\(machine.name)”: \(complaint).")
                }
                // What went wrong is in the last thing that was said: ssh and sudo lead up to it.
                let reason = error.output.standardError.split(whereSeparator: \.isNewline).last
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let detail = reason.isEmpty ? "" : " (\(reason))"
                if machine.configuration.os.family == .macOS {
                    let advice = request.password == nil
                        ? "Give the password with --password <password>, or install from inside the guest with `virtualvm install-tools <machine> --disc`."
                        : "To install from inside the guest instead, use `virtualvm install-tools <machine> --disc`."
                    return .failure("The guest tools couldn't be installed over SSH, which takes key sign-in and the account's password\(detail). \(advice)")
                }
                return .failure("The guest tools couldn't be installed over SSH, which takes key sign-in and sudo without a password\(detail). To install from inside the guest instead, use `virtualvm install-tools <machine> --disc`.")
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .shareClipboard:
            guard let isOn = request.isOn else { return .failure("Missing on or off.") }
            // A Linux guest shares the clipboard through a device, which like all hardware is there
            // from the start or not at all. A macOS guest's agent is simply told, or no longer told.
            guard machine.configuration.os.family == .macOS || machine.state == .stopped
                || machine.configuration.clipboard.isShared == isOn
            else {
                return .failure("Shut down “\(machine.name)” first: this guest shares the clipboard through a device, which can't be added or taken away while it is up or suspended.")
            }
            changeConfiguration(of: machine) { $0.clipboard.isShared = isOn }
            if machine.lastError == nil {
                return details(machine)
            }
        case .usbAttach, .usbDetach, .usbAuto:
            guard let wanted = request.usbDevice, !wanted.isEmpty else { return .failure("Missing USB device.") }
            do {
                switch request.command {
                case .usbAttach:
                    // In a copy that has no USB devices at all, that says more than "no such device".
                    guard usb.availability == .available else { throw USBPassthrough.Failure.unavailable(usb.availability) }
                    try await usb.attach(try findUSBDevice(wanted, among: usb.devices, preferringFree: true), to: machine)
                case .usbDetach:
                    guard !machine.usbDevices.matching(wanted).isEmpty else {
                        return .failure("“\(wanted)” isn't attached to “\(machine.name)”.")
                    }
                    try await usb.detach(try findUSBDevice(wanted, among: machine.usbDevices), from: machine)
                default:
                    guard let isOn = request.isOn else { return .failure("Missing on or off.") }
                    let rules = machine.configuration.usb.autoConnect
                    if !isOn, let rule = rules.first(where: { $0.id == wanted.lowercased() || $0.name.lowercased() == wanted.lowercased() }) {
                        // A rule can be taken back while its device is somewhere else.
                        try machine.updateConfiguration { $0.usb.autoConnect.removeAll { $0.id == rule.id } }
                    } else {
                        guard usb.availability == .available else { throw USBPassthrough.Failure.unavailable(usb.availability) }
                        let device = try findUSBDevice(wanted, among: usb.devices, anyOfOneMake: true)
                        try usb.setConnectsAutomatically(isOn, device, to: machine)
                        if isOn, machine.state == .running {
                            // The machine takes a device that is free a moment from now. Wait for that,
                            // so that the answer shows it.
                            let deadline = ContinuousClock.now + .seconds(2)
                            while usb.devices.contains(where: { $0.id == device.id }), usb.holder(of: device.id) == nil,
                                  ContinuousClock.now < deadline {
                                try? await Task.sleep(for: .milliseconds(50))
                            }
                        }
                    }
                }
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .discardState:
            guard machine.state == .suspended else { return .failure("“\(machine.name)” isn't suspended.") }
            machine.discardSavedState()
        case .resize:
            guard let gigabytes = request.diskGigabytes, gigabytes > 0 else { return .failure("Missing disk size.") }
            guard gigabytes <= HostResources.maximumDiskGigabytes else {
                return .failure("\(gigabytes) GB is more than a disk can have (\(HostResources.maximumDiskGigabytes) GB). The size is in GB.")
            }
            do {
                try await resizeDisk(of: machine, to: UInt64(gigabytes) * HostResources.gibibyte)
            } catch {
                return .failure(error.localizedDescription)
            }
        case .clone:
            do {
                return success(try await duplicate(machine, named: request.name))
            } catch {
                return .failure(error.localizedDescription)
            }
        case .snapshot:
            do {
                try await machine.takeSnapshot(named: request.name)
            } catch {
                return .failure(error.localizedDescription)
            }
            // The guest is resumed afterwards; if that failed, say so rather than report success.
            if let error = machine.lastError {
                machine.lastError = nil
                return .failure("The snapshot was taken, but: \(error.title): \(error.message)")
            }
            return snapshots(of: machine)
        case .snapshots:
            return snapshots(of: machine)
        case .revert, .deleteSnapshot, .renameSnapshot:
            guard let identifier = request.snapshot else { return .failure("Missing snapshot name.") }
            let newName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard request.command != .renameSnapshot || !newName.isEmpty else {
                return .failure("Missing the snapshot's new name.")
            }
            let found = findSnapshot(identifier, of: machine)
            guard case .success(let snapshot) = found else {
                if case .failure(let problem) = found { return .failure(problem.message) }
                return .failure("No such snapshot.")
            }
            do {
                if request.command == .revert {
                    try await machine.revert(to: snapshot)
                } else if request.command == .renameSnapshot {
                    try machine.renameSnapshot(snapshot, to: newName)
                    return snapshots(of: machine)
                } else {
                    try machine.deleteSnapshot(snapshot)
                    return snapshots(of: machine)
                }
            } catch {
                return .failure(error.localizedDescription)
            }
        case .list, .info, .console, .vsock, .create, .quit, .usbList:
            break
        }

        // The command-line caller gets the error, so don't also raise an alert in the app.
        if let error = machine.lastError {
            machine.lastError = nil
            return .failure("\(error.title): \(error.message)")
        }
        return success(machine)
    }
}
