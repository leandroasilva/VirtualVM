import AppKit
import Installers
import VMControl
import VMCore
import VZEngine
extension AppModel {
    // MARK: Creating

    func createMachine(_ parameters: ControlRequest.CreateParameters) async -> ControlResponse {
        let isMac = parameters.distribution == ControlRequest.CreateParameters.macOS
        let distribution = DistributionCatalog.quickCreate.first { $0.id == parameters.distribution }
        guard isMac || distribution != nil else {
            let available = ([ControlRequest.CreateParameters.macOS] + DistributionCatalog.quickCreate.map(\.id)).joined(separator: ", ")
            return .failure("Unknown system “\(parameters.distribution)”. Available: \(available).")
        }
        let family: GuestFamily = isMac ? .macOS : .linux
        var name = parameters.name ?? distribution?.name.replacingOccurrences(of: " LTS", with: "") ?? "macOS"
        if parameters.name == nil {
            let base = name
            var counter = 2
            while isNameTaken(name) {
                name = "\(base) \(counter)"
                counter += 1
            }
        } else if isNameTaken(name) {
            return .failure("A virtual machine named “\(name)” already exists.")
        }
        // Sizes are in GB. One typed in bytes would overflow further down.
        if let memory = parameters.memoryGigabytes, !(1...Int(HostResources.memorySize / HostResources.gibibyte)).contains(memory) {
            return .failure("\(memory) GB of memory is more than this Mac has. The size is in GB.")
        }
        if let disk = parameters.diskGigabytes, !(1...HostResources.maximumDiskGigabytes).contains(disk) {
            return .failure("\(disk) GB is more than a disk can have (\(HostResources.maximumDiskGigabytes) GB). The size is in GB.")
        }
        let cpuCount = parameters.cpuCount ?? HostResources.recommendedCPUCount(for: family)
        let memorySize = parameters.memoryGigabytes.map { UInt64($0) * HostResources.gibibyte }
            ?? HostResources.recommendedMemorySize(for: family)
        let diskCapacity = parameters.diskGigabytes.map { UInt64($0) * HostResources.gibibyte }
            ?? HostResources.recommendedDiskCapacity(for: family)

        let start: () -> MachineCreation
        if let distribution {
            let request = LinuxQuickCreateRequest(
                name: name,
                distribution: distribution,
                cpuCount: cpuCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity,
                userName: parameters.user ?? NSUserName(),
                fullName: NSFullUserName(),
                password: parameters.password ?? "",
                installsSSHKey: true,
                rosetta: false
            )
            start = { self.create(request) }
        } else {
            var image: MacRestoreImage?
            if let path = parameters.restoreImagePath {
                do {
                    image = try await MacRestoreImage.load(from: URL(fileURLWithPath: path))
                } catch {
                    return .failure("Couldn't read the restore image: \(error.localizedDescription)")
                }
            }
            // Without an image the latest macOS is installed, which sets up the account by itself.
            var account: GuestProvisioning?
            if image?.supportsProvisioning ?? true {
                let userName = parameters.user ?? NSUserName()
                if let problem = GuestProvisioning.problem(withUserName: userName) {
                    return .failure("“\(userName)” can't be the account name. \(problem)")
                }
                guard let password = parameters.password, !password.isEmpty else {
                    return .failure("macOS needs a password for the account. Add --password <password>.")
                }
                let provisioning = GuestProvisioning(fullName: NSFullUserName(), userName: userName, password: password)
                do {
                    try provisioning.validateForMacOS()
                } catch {
                    return .failure("macOS can't create that account: \(error.localizedDescription)")
                }
                account = provisioning
            }
            let request = MacInstallRequest(
                name: name,
                image: image,
                cpuCount: cpuCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity,
                account: account,
                installsSSHKey: true
            )
            start = { self.create(request) }
        }

        // A quit may have been agreed to while the restore image was being read.
        guard !isQuittingUnattended else { return .failure("\(AppIdentity.current.name) is quitting.") }
        let result: Result<VirtualMachine, any Error> = await withCheckedContinuation { continuation in
            let creation = start()
            creation.onFinish = { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let machine):
            if parameters.start {
                guard !isQuittingUnattended else {
                    return .failure("“\(machine.name)” was created but not started, because \(AppIdentity.current.name) is quitting.")
                }
                await machine.start()
                if let error = machine.lastError {
                    machine.lastError = nil
                    return .failure("\(error.title): \(error.message)")
                }
            }
            return success(machine)
        case .failure(let error):
            // The caller reports the failure; don't leave a failed row behind in the menu bar panel.
            creations.removeAll { $0.name == name && $0.errorMessage != nil }
            return .failure(error.localizedDescription)
        }
    }
}
