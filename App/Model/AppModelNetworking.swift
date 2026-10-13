import Foundation
import VMCore
import VMNetworking

extension AppModel {
    // MARK: Networking

    /// The address reserved for every machine, applied when the default network is created.
    func networkPlan() -> NetworkPlan {
        var plan = NetworkPlan()
        for machine in library.machines {
            for interface in machine.configuration.networkInterfaces {
                guard let macAddress = MACAddress(interface.macAddress),
                      let address = interface.ipv4Address.flatMap(IPv4Address.init)
                else { continue }
                plan.reservations.append(.init(macAddress: macAddress, address: address))
            }
        }
        return plan
    }

    /// Forwards a port on this Mac to a port in `machine`. Takes effect at once if the machine is running.
    func addPortForward(_ forward: PortForward, to machine: VirtualMachine) throws {
        guard forward.hostPort > 0, forward.guestPort > 0 else {
            throw VMError.invalidConfiguration("Ports are numbers from 1 to 65535.")
        }
        guard !machine.configuration.networkInterfaces.isEmpty else {
            throw VMError.invalidConfiguration("“\(machine.name)” has no network interface.")
        }
        for other in library.machines {
            let taken = other.configuration.networkInterfaces.flatMap(\.portForwards)
                .contains { $0.hostPort == forward.hostPort && $0.transport == forward.transport }
            if taken {
                let owner = other.id == machine.id ? "this virtual machine" : "“\(other.name)”"
                throw VMError.invalidConfiguration(
                    "\(forward.transport.rawValue.uppercased()) port \(forward.hostPort) on this Mac already leads to \(owner)."
                )
            }
        }
        try machine.updateConfiguration { $0.networkInterfaces[0].portForwards.append(forward) }
    }

    func removePortForward(_ id: UUID, from machine: VirtualMachine) throws {
        try machine.updateConfiguration { configuration in
            for index in configuration.networkInterfaces.indices {
                configuration.networkInterfaces[index].portForwards.removeAll { $0.id == id }
            }
        }
    }

    /// Opens the forwarded ports of machines that are running and closes those of machines that aren't.
    /// Called whenever something they depend on may have changed, and regularly to retry ports that
    /// couldn't be opened.
    func syncPortForwards() {
        var routes: [UUID: PortRelay.Route] = [:]
        for machine in library.machines where machine.state == .running || machine.state == .paused {
            guard let address = address(for: machine).flatMap(IPv4Address.init) else { continue }
            for forward in machine.configuration.networkInterfaces.flatMap(\.portForwards) {
                routes[forward.id] = PortRelay.Route(
                    transport: forward.transport, hostPort: forward.hostPort,
                    guestAddress: address, guestPort: forward.guestPort,
                    allowsOtherDevices: forward.allowsOtherDevices
                )
            }
        }
        portForwarder.apply(routes)
    }

    func syncClipboardSharing() {
        for machine in library.machines {
            clipboardSharing.update(machine)
        }
    }

    /// Moves every machine's reserved address along when the default network changes subnet.
    func remapReservedAddresses(from previous: IPv4Subnet, to current: IPv4Subnet) {
        for machine in library.machines {
            do {
                try machine.updateConfiguration { configuration in
                    for index in configuration.networkInterfaces.indices {
                        guard let address = configuration.networkInterfaces[index].ipv4Address.flatMap(IPv4Address.init),
                              previous.contains(address)
                        else { continue }
                        configuration.networkInterfaces[index].ipv4Address =
                            NetworkManager.remap(address, from: previous, to: current).description
                    }
                }
            } catch {
                appLog.error("Couldn't move “\(machine.name, privacy: .public)” to the network's new subnet: \(error.localizedDescription, privacy: .public)")
            }
        }
        syncSSHConfiguration()
    }

    /// An unused address on the default network for a new machine.
    func allocateAddress() -> IPv4Address? {
        guard let networkManager else { return nil }
        let used = Set(library.machines.flatMap { machine in
            machine.configuration.networkInterfaces.compactMap { $0.ipv4Address.flatMap(IPv4Address.init) }
        })
        return networkManager.defaultSubnet.firstAvailableAddress(excluding: used)
    }

    /// The address the guest is reachable at from the host, if known.
    ///
    /// While a machine runs this is the address it actually holds; otherwise the one reserved for it.
    func address(for machine: VirtualMachine) -> String? {
        if machine.state.isActive, let observed = observedAddresses[machine.id] {
            return observed
        }
        return machine.configuration.networkInterfaces.first?.ipv4Address
    }

    /// Works out the address each active machine currently holds and updates the SSH hosts if any changed.
    ///
    /// A guest whose agent is connected says so itself. For the others: a guest normally gets its reserved
    /// address. One whose DHCP client doesn't identify itself by MAC address is handed a different one,
    /// which shows up in the lease database. When there is more than one candidate, the one that accepts a
    /// connection on the SSH port wins.
    func refreshObservedAddresses() async {
        guard let networkManager else { return }
        var updated: [UUID: String] = [:]
        for machine in library.machines where machine.state.isActive {
            guard let interface = machine.configuration.networkInterfaces.first,
                  let macAddress = MACAddress(interface.macAddress)
            else { continue }
            if machine.agent.isConnected {
                // A guest with the agent says which address it holds, and nothing has to be worked out.
                // That is the address of the machine's network card, or, where the card is part of a
                // bridge or a bond with a hardware address of its own, whichever address is on the
                // app's network.
                let subnet = networkManager.defaultSubnet
                let onCard = machine.agent.addresses(ofInterface: interface.macAddress).compactMap(IPv4Address.init)
                let reported = onCard.first(where: subnet.contains) ?? onCard.first
                    ?? machine.agent.addresses.compactMap(IPv4Address.init).first(where: subnet.contains)
                if let reported {
                    updated[machine.id] = reported.description
                    lastSeenAddresses[machine.id] = reported.description
                    continue
                }
                // It reports none: its cable is out, it is still asking for an address, or its agent
                // can't tell. Then it is worked out as for any guest, with one difference below.
            }
            let hasAgent = machine.agent.isConnected
            // Where the machine was last known to be for certain, or failing that where it was listed.
            // With an agent on the line the listing was itself only a guess.
            let previous = (lastSeenAddresses[machine.id] ?? (hasAgent ? nil : observedAddresses[machine.id])).flatMap(IPv4Address.init)
            let ssh = machine.configuration.ssh
            var candidates = DHCPLeases.currentAddresses(macAddress: macAddress, hostName: ssh.alias, in: networkManager.defaultSubnet)
            if let reserved = networkManager.activeReservation(for: macAddress), !candidates.contains(reserved) {
                candidates.append(reserved)
            }
            guard var chosen = candidates.first else { continue }
            if candidates.count > 1 {
                var answering: IPv4Address?
                for candidate in candidates where await Reachability.canConnect(to: candidate, port: ssh.port) {
                    answering = candidate
                    break
                }
                // While nothing answers (still starting up), keep what was shown before rather than flip
                // around. A guest whose agent is there and reports no address most likely holds none
                // yet: a lease on the books is then history, and the reserved address is where it will
                // turn up.
                let expected = hasAgent ? networkManager.activeReservation(for: macAddress) : nil
                chosen = answering ?? previous.flatMap { candidates.contains($0) ? $0 : nil } ?? expected ?? chosen
                if let answering {
                    lastSeenAddresses[machine.id] = answering.description
                }
            }
            updated[machine.id] = chosen.description
        }
        if updated != observedAddresses {
            observedAddresses = updated
            syncSSHConfiguration()
        }
        syncPortForwards()
    }

    /// Keeps observed addresses current while machines run. Reading the small lease file is cheap.
    ///
    /// One round runs at a time, every two seconds, and sooner when ``refreshAddressesSoon()`` asks.
    func startAddressMonitor() {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshObservedAddresses()
                guard let self else { return }
                if isAddressRefreshDue {
                    isAddressRefreshDue = false
                    continue
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled {
                        self?.refreshAddressesSoon()
                    }
                }
                await withCheckedContinuation { self.addressMonitorPause = $0 }
                timer.cancel()
            }
        }
    }

    /// Has the address monitor look again now rather than at its next turn.
    func refreshAddressesSoon() {
        guard let pause = addressMonitorPause else {
            // A round is under way and may have looked at this machine already.
            isAddressRefreshDue = true
            return
        }
        addressMonitorPause = nil
        pause.resume()
    }
}
