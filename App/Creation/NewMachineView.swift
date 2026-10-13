import Installers
import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// What the New Virtual Machine form starts with.
struct NewMachineRequest: Identifiable {
    enum Source {
        /// Ask which system to install.
        case chooser
        /// A Linux installer disc image, for example one that was dropped on the window.
        case installerDisc(URL)
        /// A macOS restore image (IPSW).
        case restoreImage(URL)
    }

    let id = UUID()
    var source = Source.chooser

    /// The request for a file dropped on the window, or `nil` if a machine can't be made from it.
    init?(droppedFile url: URL) {
        switch url.pathExtension.lowercased() {
        case "iso": source = .installerDisc(url)
        case "ipsw": source = .restoreImage(url)
        default: return nil
        }
    }

    init() {}
}

/// The form that creates a new virtual machine, shown in the New Virtual Machine window.
struct NewMachineView: View {
    /// Called when the new machine is in the library; the flag says whether to start it right away.
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var family: GuestFamily?
    /// The file the form was opened for. Going back to the chooser forgets it.
    @State private var source: NewMachineRequest.Source

    init(request: NewMachineRequest = NewMachineRequest(), onReady: @escaping (VirtualMachine, Bool) -> Void) {
        self.onReady = onReady
        _source = State(initialValue: request.source)
        switch request.source {
        case .chooser: _family = State(initialValue: nil)
        case .installerDisc: _family = State(initialValue: .linux)
        case .restoreImage: _family = State(initialValue: .macOS)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch family {
            case nil:
                SystemChooser(selection: $family)
            case .linux:
                LinuxMachineForm(initialDisc: initialDisc, onBack: goBack, onReady: onReady)
            case .macOS:
                MacMachineForm(initialImage: initialImage, onBack: goBack, onReady: onReady)
            case .windows:
                // Not reachable yet: the chooser only offers systems that can be created.
                SystemChooser(selection: $family)
            }
        }
        .frame(width: 600)
    }

    private var initialDisc: URL? {
        if case .installerDisc(let url) = source { return url }
        return nil
    }

    private var initialImage: URL? {
        if case .restoreImage(let url) = source { return url }
        return nil
    }

    private func goBack() {
        source = .chooser
        family = nil
    }
}

// MARK: - Choosing a system

private struct SystemChooser: View {
    @Binding var selection: GuestFamily?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            // The window's title bar says what this is.
            Text("Choose the operating system to install.")
                .font(.title3.weight(.medium))
                .padding(.top, 22)

            HStack(spacing: 14) {
                card(.macOS, detail: "The latest version, or your own restore image", isAvailable: true)
                card(.linux, detail: "Ubuntu, Debian and more", isAvailable: true)
                card(.windows, detail: "Coming soon", isAvailable: false)
            }
            .padding(.horizontal, 26)

            HStack {
                Text("Or drop an installer disc (ISO), a macOS restore image (IPSW) or a virtual machine here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
    }

    private func card(_ family: GuestFamily, detail: String, isAvailable: Bool) -> some View {
        Button {
            selection = family
        } label: {
            VStack(spacing: 10) {
                OSGlyph(os: GuestOS(family: family, distribution: family == .linux ? "ubuntu" : nil), size: 54)
                Text(family.displayName)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(isAvailable), in: .rect(cornerRadius: 20))
        .opacity(isAvailable ? 1 : 0.5)
        .disabled(!isAvailable)
    }
}
