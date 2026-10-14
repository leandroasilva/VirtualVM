import SwiftUI
import VMCore

/// Per-machine settings. Hardware changes apply the next time the machine starts; sharing and the network
/// cable apply immediately.
struct MachineSettingsView: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sshUser = ""
    @State private var isResizingDisk = false
    /// The processor and memory controls work on these and persist at the end of a burst of changes:
    /// dragging the slider would otherwise write the bundle on every tick.
    @State private var cpuCount = 1
    @State private var memoryGiB = 1.0
    @State private var pendingHardware: ((inout VMConfiguration) -> Void)?
    @State private var hardwareCommitTask: Task<Void, Never>?

    private var configuration: VMConfiguration { machine.configuration }
    private var isActive: Bool { machine.state != .stopped }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                generalSection
                resourcesSection
                storageSection
                sharingSection
                clipboardSection
                networkSection
                if !configuration.networkInterfaces.isEmpty {
                    portForwardingSection
                }
                // A copy that isn't signed for USB devices has none to show, but a machine may have been
                // told elsewhere to take some by itself, and that can be taken back here.
                if model.usb.availability != .notSigned || !configuration.usb.autoConnect.isEmpty {
                    usbSection
                }
                devicesSection
                keyboardSection
                if configuration.os.family == .linux {
                    bootSection
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isActive {
                    Label("Changes to hardware apply after the virtual machine is shut down and started again.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    commitTextFields()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            name = configuration.name
            sshUser = configuration.ssh.user
            cpuCount = configuration.cpuCount
            memoryGiB = Double(configuration.memorySize / HostResources.gibibyte)
        }
        // In a window of their own the settings can be closed without Done. What was typed is kept all
        // the same.
        .onDisappear(perform: commitTextFields)
    }

    // MARK: Sections

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $name)
                .onSubmit(commitTextFields)
            LabeledContent("System", value: configuration.os.summary)
            LabeledContent("Location") {
                Button((machine.bundle.url.path as NSString).abbreviatingWithTildeInPath) {
                    model.revealInFinder(machine)
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Show in Finder")
            }
        }
    }

    private var resourcesSection: some View {
        Section("Processor and Memory") {
            Stepper(value: cpuBinding, in: 1...HostResources.cpuCount) {
                LabeledContent("Processors", value: "\(cpuCount)")
            }
            LabeledContent("Memory") {
                HStack {
                    Slider(value: memoryBinding, in: 1...Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), step: 1)
                        .accessibilityLabel("Memory")
                        .accessibilityValue(Formatting.bytes(memoryBytes))
                    Text(Formatting.bytes(memoryBytes))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .disabled(isActive)
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Disk") {
                HStack {
                    Text("\(Formatting.bytes(machine.allocatedDiskSize)) used of \(Formatting.bytes(configuration.totalDiskCapacity))")
                    Button("Resize…") { isResizingDisk = true }
                        .disabled(machine.state != .stopped || machine.activity != nil || configuration.systemDisk == nil)
                        .help(machine.state == .stopped ? "Make the disk larger" : "Shut down the virtual machine to resize its disk")
                        .popover(isPresented: $isResizingDisk, arrowEdge: .bottom) {
                            ResizeDiskView(machine: machine)
                        }
                }
            }
            RemovableDrivesEditor(machine: machine)
        } header: {
            Text("Storage")
        } footer: {
            Text("The disk only takes up what the guest has written to it. Disc and disk images are plugged in as USB drives and can be changed while the virtual machine runs.")
        }
    }

    private var sharingSection: some View {
        Section {
            SharedFoldersEditor(machine: machine)
        } header: {
            Text("Shared Folders")
        } footer: {
            SharedFoldersGuestHint(configuration: configuration, isMountedByAgent: machine.hasAgentMountedSharedFolders)
        }
    }

    private var clipboardSection: some View {
        Section {
            Toggle("Share Clipboard", isOn: binding(\.clipboard.isShared))
                // Linux guests share it through a device, which like all hardware is there from the start
                // or not at all.
                .disabled(configuration.os.family != .macOS && isActive)
        } header: {
            Text("Clipboard")
        } footer: {
            Text(configuration.os.family == .macOS
                ? "Text you copy on this Mac can be pasted in the virtual machine, and the other way round. This needs the guest tools in the virtual machine."
                : "Text you copy on this Mac can be pasted in the virtual machine, and the other way round. This needs spice-vdagent in the guest, which most desktop systems bring along.")
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section {
            if let interface = configuration.networkInterfaces.first {
                Toggle("Connected", isOn: binding(\.networkInterfaces[0].isConnected))
                LabeledContent("IP Address", value: model.address(for: machine) ?? "Assigned when the machine starts")
                LabeledContent("MAC Address", value: interface.macAddress)
            } else {
                Text("This virtual machine has no network interface.")
                    .foregroundStyle(.secondary)
            }
            TextField("SSH User", text: $sshUser, prompt: Text(NSUserName()))
                .onSubmit(commitTextFields)
            if let command = model.sshCommand(for: machine) {
                LabeledContent("Connect") {
                    Text(command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Network and SSH")
        } footer: {
            if !model.isSSHIncludeInstalled {
                Text("Turn on “Add machines to ~/.ssh/config” in VirtualVM Settings to connect with just “ssh \(configuration.ssh.alias)”.")
            }
        }
    }

    private var portForwardingSection: some View {
        Section {
            PortForwardsEditor(machine: machine)
        } header: {
            Text("Port Forwarding")
        } footer: {
            Text("A forwarded port makes a service in the guest reachable as localhost on this Mac, for example localhost:8080 for a web server on port 80. The guest can always be reached at its own address without forwarding.")
        }
    }

    private var usbSection: some View {
        Section {
            USBDevicesEditor(machine: machine)
        } header: {
            Text("USB Devices")
        } footer: {
            USBDevicesFootnote()
        }
    }

    private var devicesSection: some View {
        Section("Devices") {
            Toggle("Sound Output", isOn: binding(\.audio.outputEnabled))
            Toggle("Microphone", isOn: binding(\.audio.inputEnabled))
            Toggle("Resize Display with Window", isOn: binding(\.display.automaticallyResizes))
        }
        .disabled(isActive)
    }

    private var keyboardSection: some View {
        Section {
            Toggle("Send System Shortcuts to the Guest", isOn: binding(\.keyboard.capturesSystemKeys))
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Shortcuts such as Command-Tab and Command-Space go to the guest while its window has focus. Turn this off to keep them for your Mac.")
        }
    }

    private var bootSection: some View {
        Section {
            Toggle("Secure Boot", isOn: binding(\.boot.secureBoot))
            Toggle("Rosetta for x86-64 Programs", isOn: binding(\.boot.rosetta))
        } header: {
            Text("Startup")
        } footer: {
            Text("Secure Boot only starts systems signed with Microsoft's UEFI keys, which most major distributions are.")
        }
        .disabled(isActive)
    }

    // MARK: Editing

    private var memoryBytes: UInt64 { UInt64(memoryGiB) * HostResources.gibibyte }

    private var cpuBinding: Binding<Int> {
        Binding(
            get: { cpuCount },
            set: { newValue in
                cpuCount = newValue
                scheduleHardwareCommit { $0.cpuCount = newValue }
            }
        )
    }

    private var memoryBinding: Binding<Double> {
        Binding(
            get: { memoryGiB },
            set: { newValue in
                memoryGiB = newValue
                scheduleHardwareCommit { $0.memorySize = UInt64(newValue) * HostResources.gibibyte }
            }
        )
    }

    /// Persists a hardware change once the user stops making them, so that a slider drag or a held
    /// stepper writes the bundle once instead of on every tick. Changes made in one burst are composed:
    /// a stepper tick followed by a slider tick commits both.
    private func scheduleHardwareCommit(_ body: @escaping (inout VMConfiguration) -> Void) {
        let previous = pendingHardware
        pendingHardware = { updated in
            previous?(&updated)
            body(&updated)
        }
        hardwareCommitTask?.cancel()
        hardwareCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            flushPendingHardware()
        }
    }

    private func flushPendingHardware() {
        hardwareCommitTask?.cancel()
        hardwareCommitTask = nil
        guard let body = pendingHardware else { return }
        pendingHardware = nil
        update(body)
        // Bring the mirrors back to what the machine actually holds: what wasn't saved, perhaps for a
        // bundle write that failed, shows as what is saved rather than as unsaved.
        cpuCount = machine.configuration.cpuCount
        memoryGiB = Double(machine.configuration.memorySize / HostResources.gibibyte)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VMConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { machine.configuration[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func commitTextFields() {
        flushPendingHardware()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        update { configuration in
            if !trimmedName.isEmpty {
                configuration.name = trimmedName
            }
            configuration.ssh.user = trimmedUser
        }
        name = machine.configuration.name
    }

    private func update(_ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't save the settings", message: error.localizedDescription)
        }
    }
}
