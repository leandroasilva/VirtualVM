import Installers
import SwiftUI
import UniformTypeIdentifiers
import VMCore


// MARK: - macOS

struct MacMachineForm: View {
    /// What is known about the newest macOS this Mac can run.
    enum LatestImage {
        case loading
        case available(MacRestoreImage)
        case unavailable(String)
    }

    /// A restore image to start with, instead of the latest macOS.
    var initialImage: URL?
    let onBack: () -> Void
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var latest = LatestImage.loading
    /// Size of the download for the latest image, when it isn't in the cache yet.
    @State private var latestDownloadSize: Int64?
    @State private var lookupAttempt = 0
    @State private var localImage: MacRestoreImage?
    @State private var localImageProblem: String?
    @State private var usesLocalImage = false
    @State private var name = ""
    @State private var hasEditedName = false
    @State private var cpuCount = HostResources.recommendedCPUCount(for: .macOS)
    @State private var memoryGigabytes = Double(HostResources.recommendedMemorySize(for: .macOS) / HostResources.gibibyte)
    @State private var diskGigabytes = Int(HostResources.recommendedDiskCapacity(for: .macOS) / HostResources.gibibyte)
    @State private var fullName = NSFullUserName()
    @State private var userName = NSUserName()
    @State private var password = ""
    @State private var logsInAutomatically = true
    @State private var installsSSHKey = true

    private static let diskSizes = [64, 128, 256, 512, 1024]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Version", selection: versionBinding) {
                        Text(latestTitle).tag(false)
                        if let localImage {
                            Text("\(localImage.productName) (\(localImage.url.lastPathComponent))").tag(true)
                        }
                    }
                    LabeledContent("") {
                        HStack {
                            if case .unavailable = latest {
                                Button("Try Again") { lookupAttempt += 1 }
                            }
                            Button("Choose Restore Image…") { chooseImage() }
                        }
                    }
                    TextField("Name", text: nameBinding)
                } footer: {
                    if let problem = sourceProblem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text(sourceNote)
                    }
                }

                Section("Hardware") {
                    Stepper(value: $cpuCount, in: minimumCPUCount...max(HostResources.cpuCount, minimumCPUCount)) {
                        LabeledContent("Processors", value: "\(cpuCount)")
                    }
                    LabeledContent("Memory") {
                        HStack {
                            // A slider needs room to move; on a small Mac the minimum is all there is.
                            if maximumMemoryGigabytes > minimumMemoryGigabytes {
                                Slider(value: $memoryGigabytes, in: minimumMemoryGigabytes...maximumMemoryGigabytes, step: 1)
                                    .accessibilityLabel("Memory")
                                    .accessibilityValue("\(Int(memoryGigabytes)) GB")
                            }
                            Text("\(Int(memoryGigabytes)) GB")
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    Picker("Disk Size", selection: $diskGigabytes) {
                        ForEach(Self.diskSizes, id: \.self) { size in
                            Text(size >= 1024 ? "\(size / 1024) TB" : "\(size) GB").tag(size)
                        }
                    }
                }

                if setsUpAccount {
                    Section {
                        TextField("Full Name", text: $fullName)
                        TextField("Account Name", text: $userName)
                        SecureField("Password", text: $password, prompt: Text("Required"))
                        Toggle("Log in automatically", isOn: $logsInAutomatically)
                        Toggle("Sign in over SSH with my key", isOn: $installsSSHKey)
                    } header: {
                        Text("Account")
                    } footer: {
                        if let problem = accountProblem {
                            Text(problem).foregroundStyle(.red)
                        } else {
                            Text("macOS creates this account the first time it starts, so there is no setup assistant to click through. The virtual machine starts as soon as it is installed.")
                        }
                    }
                } else {
                    Section("Account") {
                        Text("Versions before macOS \(GuestProvisioning.minimumMacOSMajorVersion) can't be set up automatically. Create the account in the setup assistant when the virtual machine first starts.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            HStack {
                Button("Back", action: onBack)
                Spacer()
                if let problem = nameProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(16)
        }
        .frame(height: 620)
        .task(id: lookupAttempt) { await lookUpLatest() }
        .task {
            if let initialImage {
                await useLocalImage(at: initialImage)
            }
        }
        .onAppear { suggestName() }
        .onChange(of: selectedImage) {
            suggestName()
            // A newer system can ask for more than the defaults.
            cpuCount = max(cpuCount, minimumCPUCount)
            memoryGigabytes = min(max(memoryGigabytes, minimumMemoryGigabytes), maximumMemoryGigabytes)
        }
    }

    // MARK: Restore image

    private var selectedImage: MacRestoreImage? {
        if usesLocalImage {
            return localImage
        }
        if case .available(let image) = latest {
            return image
        }
        return nil
    }

    /// Switching versions by hand puts an earlier complaint about a file out of date.
    private var versionBinding: Binding<Bool> {
        Binding(get: { usesLocalImage }, set: { newValue in
            usesLocalImage = newValue
            localImageProblem = nil
        })
    }

    private var latestTitle: String {
        switch latest {
        case .loading: "Latest macOS"
        case .available(let image): "Latest (\(image.productName))"
        case .unavailable: "Latest macOS (unavailable)"
        }
    }

    /// Why the chosen version can't be installed, if it can't.
    private var sourceProblem: String? {
        // A file that was just turned down is what the user is looking at, whatever is still selected.
        if let localImageProblem {
            return localImageProblem
        }
        if usesLocalImage {
            if let localImage, localImage.requirements == nil {
                return "This Mac can't run \(localImage.productName) in a virtual machine."
            }
            return nil
        }
        if case .unavailable(let reason) = latest {
            return "Couldn't look up the latest macOS: \(reason) You can still install from a restore image file."
        }
        return nil
    }

    private var sourceNote: String {
        guard let image = selectedImage else { return "Checking for the latest macOS…" }
        if usesLocalImage {
            return "Installs \(image.guestOS.summary) from the chosen file. This takes several minutes."
        }
        if model.downloader.isCached(RemoteImage(url: image.url)) {
            return "\(image.guestOS.summary) is already downloaded. Installing it takes several minutes."
        }
        if let latestDownloadSize {
            return "Downloads \(image.guestOS.summary) from Apple (\(Formatting.bytes(UInt64(latestDownloadSize)))) and installs it. This takes a while; you can keep using your Mac."
        }
        return "Downloads \(image.guestOS.summary) from Apple and installs it. This takes a while; you can keep using your Mac."
    }

    private func lookUpLatest() async {
        latest = .loading
        do {
            let image = try await model.latestMacRestoreImage()
            latest = .available(image)
            let remote = RemoteImage(url: image.url)
            if image.isRemote, !model.downloader.isCached(remote) {
                latestDownloadSize = await model.downloader.remoteSize(of: remote)
            }
        } catch {
            guard !Task.isCancelled else { return }
            latest = .unavailable(error.localizedDescription)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.message = "Choose a macOS restore image (IPSW) for Apple silicon."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await useLocalImage(at: url) }
    }

    private func useLocalImage(at url: URL) async {
        do {
            localImage = try await model.loadMacRestoreImage(from: url)
            localImageProblem = nil
            usesLocalImage = true
        } catch {
            localImageProblem = "“\(url.lastPathComponent)” isn't a usable restore image: \(error.localizedDescription)"
        }
    }

    // MARK: Limits

    private var minimumCPUCount: Int {
        selectedImage?.requirements?.minimumCPUCount ?? 2
    }

    private var minimumMemoryGigabytes: Double {
        let bytes = selectedImage?.requirements?.minimumMemorySize ?? 4 * HostResources.gibibyte
        return Double((bytes + HostResources.gibibyte - 1) / HostResources.gibibyte)
    }

    private var maximumMemoryGigabytes: Double {
        max(Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), minimumMemoryGigabytes)
    }

    // MARK: Validation

    private var setsUpAccount: Bool {
        selectedImage?.supportsProvisioning ?? true
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { newValue in
            name = newValue
            hasEditedName = true
        })
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return nil }
        return model.isNameTaken(trimmedName) ? "That name is already in use." : nil
    }

    private var account: GuestProvisioning {
        let user = userName.trimmingCharacters(in: .whitespaces)
        let full = fullName.trimmingCharacters(in: .whitespaces)
        return GuestProvisioning(
            fullName: full.isEmpty ? user : full,
            userName: user,
            password: password,
            logsInAutomatically: logsInAutomatically,
            enablesRemoteLogin: installsSSHKey
        )
    }

    /// What is wrong with the account, once the user has started filling it in.
    private var accountProblem: String? {
        let account = account
        if account.userName.isEmpty { return nil }
        if let problem = GuestProvisioning.problem(withUserName: account.userName) {
            return problem
        }
        if password.isEmpty { return nil }
        do {
            try account.validateForMacOS()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canCreate: Bool {
        guard !trimmedName.isEmpty, nameProblem == nil, selectedImage?.requirements != nil else { return false }
        guard setsUpAccount else { return true }
        return !account.userName.isEmpty && !password.isEmpty && accountProblem == nil
    }

    /// Fills in a name based on the chosen version until the user types their own.
    private func suggestName() {
        guard !hasEditedName else { return }
        let base = selectedImage.map { "macOS \($0.majorVersion)" } ?? "macOS"
        var candidate = base
        var counter = 2
        while model.isNameTaken(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        name = candidate
    }

    // MARK: Create

    private func create() {
        guard let image = selectedImage else { return }
        model.create(MacInstallRequest(
            name: trimmedName,
            image: image,
            cpuCount: cpuCount,
            memorySize: UInt64(memoryGigabytes) * HostResources.gibibyte,
            diskCapacity: UInt64(diskGigabytes) * HostResources.gibibyte,
            account: setsUpAccount ? account : nil,
            installsSSHKey: installsSSHKey
        ), onReady: { machine in
            // The account is set up on the first start, which has to happen while the app still knows it.
            onReady(machine, true)
        })
        dismiss()
    }
}
