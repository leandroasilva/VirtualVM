import AppKit
import Installers
import Observation
import SSHIntegration
import VMControl
import VMCore
import VMNetworking
import VZEngine

/// App-wide state: the machine library and the services machines depend on.
@Observable
final class AppModel {
    static let shared = AppModel()

    let library: VMLibrary
    let downloader = ImageDownloader()
    let sshWriter: SSHConfigWriter
    let keyManager = SSHKeyManager()
    /// Relays the ports that machines forward from this Mac.
    let portForwarder = PortForwarder()
    /// Passes copied text between this Mac and the guests that share their clipboard.
    let clipboardSharing = ClipboardSharing()
    /// Hands the USB devices this Mac has given the app to guests.
    let usb = USBPassthrough()
    /// Hears from macOS which USB devices those are.
    private let usbAccessories = USBAccessoryService()

    /// `nil` if the virtual network couldn't be set up; machines then can't start.
    private(set) var networkManager: NetworkManager?
    private(set) var backendProvider: (any VMBackendProvider)?

    /// Whether guests can be offered Rosetta for x86-64 Linux programs on this Mac.
    var supportsLinuxRosetta: Bool {
        backendProvider?.supportsLinuxRosetta == true
    }

    /// Asks Apple for the newest macOS this Mac can install as a guest.
    func latestMacRestoreImage() async throws -> MacRestoreImage {
        try await MacRestoreImage.latestSupported()
    }

    /// Reads the description of a local restore image file.
    func loadMacRestoreImage(from url: URL) async throws -> MacRestoreImage {
        try await MacRestoreImage.load(from: url)
    }

    /// Machines that are still being downloaded or prepared.
    var creations: [MachineCreation] = []
    /// Whether ``VMLibrary/load()`` has finished; the app draws before the machines are read in.
    private(set) var isLibraryLoaded = false
    /// Machines whose own window is open; their errors are shown there instead of in the menu bar panel.
    var openMachineWindows: Set<UUID> = []
    /// Whether the app's item is in the menu bar. It always is: with no window open the item is all there
    /// is of the app. macOS lets an item be dragged out of the menu bar all the same, so one that is
    /// taken out is put back.
    var isMenuBarItemInserted = true {
        didSet {
            guard !isMenuBarItemInserted else { return }
            Task { isMenuBarItemInserted = true }
        }
    }
    /// A problem that isn't tied to a single machine.
    var generalError: VMErrorInfo?
    /// Whether `~/.ssh/config` includes VirtualVM's generated hosts.
    var isSSHIncludeInstalled = false
    /// Addresses that running machines actually hold, by machine ID.
    var observedAddresses: [UUID: String] = [:]
    /// The address each machine was last known to hold for certain: its agent said so, or it answered
    /// there. It outlives a stop, so that a machine that comes back is first looked for where it was.
    @ObservationIgnored var lastSeenAddresses: [UUID: String] = [:]
    /// What the address monitor is waiting on between two rounds. Resuming it starts the next round early.
    @ObservationIgnored var addressMonitorPause: CheckedContinuation<Void, Never>?
    /// Someone asked for another round while one was under way.
    @ObservationIgnored var isAddressRefreshDue = false
    /// Opens the app's windows.
    @ObservationIgnored let windows = AppWindows()
    /// Whether ``offerFirstMachine()`` has had its one turn.
    @ObservationIgnored var hasOfferedFirstMachine = false
    @ObservationIgnored private var controlServer: ControlServer?
    /// The last duplication that was started. Each waits for the one before it, so that two of them can't
    /// pick the same name or SSH alias for their copies.
    @ObservationIgnored var lastDuplication: Task<Void, Never>?
    /// Set once the app has agreed to quit for the command-line tool, where there is nobody to ask what
    /// to do with machines. See ``quitUnattended()``.
    @ObservationIgnored var isQuittingUnattended = false
    @ObservationIgnored var unattendedQuitTimer: Timer?
    /// Set once the user has said how to quit with machines running, and those are being suspended or
    /// shut down. See ``closeDown()``.
    @ObservationIgnored var isClosingDown = false

    private init() {
        library = VMLibrary(rootDirectory: ControlPaths.applicationSupport)
        sshWriter = SSHConfigWriter(generatedConfigURL: library.rootDirectory.appending(path: "ssh_config"))
        isSSHIncludeInstalled = sshWriter.isIncludeInstalled

        do {
            let networkManager = try NetworkManager(rootDirectory: library.rootDirectory)
            networkManager.planProvider = { [weak self] in self?.networkPlan() ?? NetworkPlan() }
            networkManager.onDefaultSubnetChange = { [weak self] previous, current in
                self?.remapReservedAddresses(from: previous, to: current)
            }
            let provider = VZBackendProvider(networkManager: networkManager, usbAccessories: usbAccessories)
            self.networkManager = networkManager
            self.backendProvider = provider
            library.backendProvider = provider
        } catch {
            generalError = VMErrorInfo(title: "Virtual networking isn't available", message: error.localizedDescription)
        }

        library.onChange = { [weak self] in
            self?.syncSSHConfiguration()
            self?.syncPortForwards()
            // Clipboard sharing may have been turned on or off for one of them.
            self?.syncClipboardSharing()
        }
        library.onGuestAgentChange = { [weak self] machine in self?.clipboardSharing.update(machine) }
        library.onGuestClipboard = { [weak self] machine, text in self?.clipboardSharing.guest(machine, didCopy: text) }
        library.onGuestClipboardRequest = { [weak self] machine in self?.clipboardSharing.guestWantsClipboard(machine) }
        library.onMachineResume = { [weak self] machine in self?.correctClock(of: machine) }
        library.onMachineStart = { [weak self] machine in self?.usb.machineDidStart(machine) }
        usb.machines = { [weak self] in self?.library.machines ?? [] }
        usbAccessories.onConnect = { [weak self] device in self?.usb.deviceDidConnect(device) }
        usbAccessories.onDisconnect = { [weak self] id in self?.usb.deviceDidDisconnect(id) }
        // A guest that says where it is doesn't have to wait for the next round to be believed.
        library.onGuestAddressesChange = { [weak self] _ in self?.refreshAddressesSoon() }
        // Whatever was being created when the app last quit can't be finished, and opening the library is
        // disk work: it happens in ``bootstrap()``, off the initializer, so the app draws right away.
        startUSBDevices()
        Task { await bootstrap() }
    }

    /// Loads the library and starts the services that act on its machines.
    private func bootstrap() async {
        MachineNotifications.requestAuthorization()
        library.removeStagedBundles()
        await library.load()
        isLibraryLoaded = true
        // If the host has joined a network that collides with ours, move before any machine starts.
        networkManager?.relocateDefaultSubnetIfNeeded()
        startControlServer()
        startAddressMonitor()
        // The menu bar item asks for this too; whoever is ready second gets the one turn.
        offerFirstMachine()
    }

    /// Asks macOS which USB devices it has given the app, in a copy that is signed to be given any.
    private func startUSBDevices() {
        guard USBAccessoryService.isEntitled else {
            usb.availability = .notSigned
            return
        }
        Task {
            do {
                try await usbAccessories.start()
                usb.availability = .available
            } catch {
                usb.availability = .failed(error.localizedDescription)
            }
        }
    }

    /// Lets the `virtualvm` command-line tool drive the app.
    private func startControlServer() {
        do {
            controlServer = try ControlServer(
                handler: { [weak self] request in
                    await self?.handle(request) ?? .failure("\(AppIdentity.current.name) is shutting down.")
                },
                streamHandler: { [weak self] request in
                    await self?.openStream(request) ?? (.failure("\(AppIdentity.current.name) is shutting down."), nil)
                }
            )
        } catch {
            // The app works without the command-line tool; don't interrupt launch for this.
            NSLog("VirtualVM: control socket unavailable: \(error.localizedDescription)")
        }
    }

    func stopControlServer() {
        controlServer?.invalidate()
        controlServer = nil
    }

}
