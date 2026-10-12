import Foundation

/// What a macOS restore image (an IPSW file) installs and what it needs from the machine.
/// The engine reads these from Apple; this type only carries what it says.
public struct MacRestoreImage: Sendable, Hashable {
    /// What a machine must provide to run the macOS version in an image.
    public struct Requirements: Sendable, Hashable {
        /// Opaque description of the virtual Mac model the image is installed for.
        public var hardwareModel: Data
        public var minimumCPUCount: Int
        /// In bytes.
        public var minimumMemorySize: UInt64

        public init(hardwareModel: Data, minimumCPUCount: Int, minimumMemorySize: UInt64) {
            self.hardwareModel = hardwareModel
            self.minimumCPUCount = minimumCPUCount
            self.minimumMemorySize = minimumMemorySize
        }
    }

    public enum ImageError: Error, LocalizedError {
        case notAFile(URL)

        public var errorDescription: String? {
            switch self {
            case .notAFile(let url):
                "“\(url.lastPathComponent)” isn't a file on this Mac."
            }
        }
    }

    /// A local file, or the address Apple serves the image from.
    public var url: URL
    public var majorVersion: Int
    public var minorVersion: Int
    public var patchVersion: Int
    /// Build identifier, e.g. `26A434`.
    public var buildVersion: String
    /// `nil` when this Mac can't run the macOS version in the image.
    public var requirements: Requirements?

    public init(url: URL, majorVersion: Int, minorVersion: Int, patchVersion: Int, buildVersion: String, requirements: Requirements?) {
        self.url = url
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.patchVersion = patchVersion
        self.buildVersion = buildVersion
        self.requirements = requirements
    }

    /// `27.0.1`, or `27.0` when there is no patch number.
    public var versionString: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }

    /// `macOS 27.0.1`
    public var productName: String { "macOS \(versionString)" }

    public var guestOS: GuestOS {
        GuestOS(family: .macOS, productName: productName, build: buildVersion)
    }

    /// Whether the image still has to be downloaded before it can be installed.
    public var isRemote: Bool { !url.isFileURL }

    /// Whether the installed system creates the user account by itself on first boot.
    /// Provisioning is a macOS 27 API; on macOS 26 the account is made by hand in Setup Assistant.
    public var supportsProvisioning: Bool {
        if #available(macOS 27.0, *) {
            return majorVersion >= GuestProvisioning.minimumMacOSMajorVersion
        }
        return false
    }
}
