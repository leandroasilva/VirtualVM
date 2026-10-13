import AppKit
import Installers
import VMControl
import VMCore
import VZEngine
extension AppModel {
    // MARK: Helpers

    /// What to add to the news that a guest asked on its screen instead of shutting down: with the
    /// guest tools it wouldn't have. Nothing for a guest that has them and whose agent didn't answer.
    func guestToolsHint(for machine: VirtualMachine) -> String {
        machine.agent.isConnected ? "" : " With the guest tools it does so without asking: virtualvm install-tools."
    }

    /// Finds a machine by UUID, name or SSH alias (case-insensitive).
    func findMachine(_ identifier: String) -> VirtualMachine? {
        if let id = UUID(uuidString: identifier), let machine = library.machine(id: id) {
            return machine
        }
        let lowered = identifier.lowercased()
        return library.machines.first { $0.name.lowercased() == lowered }
            ?? library.machines.first { $0.configuration.ssh.alias == lowered }
    }

    struct SnapshotLookupProblem: Error {
        var message: String
    }

    /// Finds a snapshot by UUID or by name (case-insensitive).
    func findSnapshot(_ identifier: String, of machine: VirtualMachine) -> Result<VMSnapshot, SnapshotLookupProblem> {
        if let id = UUID(uuidString: identifier), let snapshot = machine.snapshots.first(where: { $0.id == id }) {
            return .success(snapshot)
        }
        let matches = machine.snapshots.filter { $0.name.lowercased() == identifier.lowercased() }
        guard let snapshot = matches.first else {
            return .failure(.init(message: "“\(machine.name)” has no snapshot named “\(identifier)”."))
        }
        guard matches.count == 1 else {
            return .failure(.init(message: "More than one snapshot is named “\(identifier)”. Use its ID from `virtualvm snapshots`."))
        }
        return .success(snapshot)
    }

    /// Finds the one USB device among `devices` that `text` names: by its number, its `vendor:product`,
    /// its serial number or its name.
    ///
    /// - Parameters:
    ///   - preferringFree: When several fit, take the one no guest has, if that is one.
    ///   - anyOfOneMake: When several of one make fit, any of them will do: what is asked for goes by make.
    func findUSBDevice(
        _ text: String, among devices: [USBDevice], preferringFree: Bool = false, anyOfOneMake: Bool = false
    ) throws -> USBDevice {
        var matches = devices.matching(text)
        if matches.count > 1, preferringFree {
            let free = matches.filter { usb.holder(of: $0.id) == nil }
            if free.count == 1 {
                matches = free
            }
        }
        if anyOfOneMake, Set(matches.map(\.identifier)).count == 1 {
            matches = Array(matches.prefix(1))
        }
        guard let device = matches.first else {
            throw VMError.invalidConfiguration("No USB device “\(text)”. `virtualvm usb` lists the ones this Mac has given \(AppIdentity.current.name).")
        }
        guard matches.count == 1 else {
            throw VMError.invalidConfiguration("More than one USB device fits “\(text)”. Use its number from `virtualvm usb`.")
        }
        return device
    }

    func summary(of device: USBDevice) -> USBDeviceSummary {
        USBDeviceSummary(
            id: device.id, name: device.name, identifier: device.identifier, manufacturer: device.manufacturer,
            serialNumber: device.serialNumber, machine: usb.holder(of: device.id)?.name
        )
    }

    func snapshots(of machine: VirtualMachine) -> ControlResponse {
        ControlResponse(ok: true, machines: [summary(of: machine)], snapshots: machine.snapshots.map { snapshot in
            SnapshotSummary(id: snapshot.id, name: snapshot.name, createdAt: snapshot.createdAt, includesMemory: snapshot.includesMemory)
        })
    }

    func details(_ machine: VirtualMachine) -> ControlResponse {
        let configuration = machine.configuration
        var summary = summary(of: machine)
        summary.details = MachineDetails(
            location: machine.bundle.url.path,
            macAddress: configuration.networkInterfaces.first?.macAddress,
            drives: configuration.removableImages.map { .init(path: $0.path, readOnly: $0.readOnly) },
            sharedFolders: configuration.sharedFolders.map { .init(name: $0.name, path: $0.path, readOnly: $0.readOnly) },
            forwards: configuration.networkInterfaces.flatMap(\.portForwards).map { forward in
                let status: String? = switch portForwarder.statuses[forward.id] {
                case .listening: "listening"
                case .starting: "starting"
                case .failed(let reason): reason
                case nil: nil
                }
                return .init(
                    hostPort: forward.hostPort, guestPort: forward.guestPort, udp: forward.transport == .udp,
                    allowsOtherDevices: forward.allowsOtherDevices, status: status
                )
            },
            snapshotCount: machine.snapshots.count,
            guestTools: configuration.canHaveGuestAgent
                ? MachineDetails.GuestTools(version: machine.agent.version, kernel: machine.agent.kernel) : nil,
            sharesClipboard: configuration.clipboard.isShared,
            usbDevices: machine.usbDevices.map { self.summary(of: $0) },
            usbAutoConnect: configuration.usb.autoConnect.map { "\($0.name) (\($0.id))" }
        )
        return ControlResponse(ok: true, machines: [summary])
    }

    func changeConfiguration(of machine: VirtualMachine, _ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't change “\(machine.name)”", message: error.localizedDescription)
        }
    }

    func waitForState(of machine: VirtualMachine, timeout: Duration, where condition: (VMState) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(machine.state) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    func summary(of machine: VirtualMachine) -> MachineSummary {
        machine.refreshDiskUsage()
        let configuration = machine.configuration
        return MachineSummary(
            id: machine.id,
            name: machine.name,
            state: machine.state.rawValue,
            system: configuration.os.summary,
            address: address(for: machine),
            sshAlias: configuration.ssh.alias.isEmpty ? nil : configuration.ssh.alias,
            cpuCount: configuration.cpuCount,
            memorySize: configuration.memorySize,
            diskAllocated: machine.allocatedDiskSize,
            diskCapacity: configuration.totalDiskCapacity
        )
    }

    func success(_ machine: VirtualMachine) -> ControlResponse {
        ControlResponse(ok: true, machines: [summary(of: machine)])
    }

    func notFound(_ identifier: String) -> ControlResponse {
        .failure("No virtual machine named “\(identifier)”.")
    }
}
