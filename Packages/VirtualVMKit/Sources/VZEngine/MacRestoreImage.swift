import Foundation
import VMCore
import Virtualization

/// Reading restore images is the engine's part: the framework knows what Apple offers and what this
/// Mac can run. What it says is carried by `VMCore.MacRestoreImage`.
extension MacRestoreImage {
    /// Asks Apple for the newest macOS this Mac can run as a guest. Needs a network connection.
    public static func latestSupported() async throws -> MacRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                continuation.resume(with: result.map(MacRestoreImage.init))
            }
        }
    }

    /// Reads the description of a restore image file.
    public static func load(from fileURL: URL) async throws -> MacRestoreImage {
        // The framework raises an exception rather than an error for anything that isn't a local file.
        var isDirectory: ObjCBool = false
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ImageError.notAFile(fileURL)
        }
        return try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: fileURL) { result in
                continuation.resume(with: result.map(MacRestoreImage.init))
            }
        }
    }

    private init(_ image: VZMacOSRestoreImage) {
        let version = image.operatingSystemVersion
        var requirements: Requirements?
        if image.isSupported, let configuration = image.mostFeaturefulSupportedConfiguration, configuration.hardwareModel.isSupported {
            requirements = Requirements(
                hardwareModel: configuration.hardwareModel.dataRepresentation,
                minimumCPUCount: configuration.minimumSupportedCPUCount,
                minimumMemorySize: configuration.minimumSupportedMemorySize
            )
        }
        self.init(
            url: image.url,
            majorVersion: version.majorVersion,
            minorVersion: version.minorVersion,
            patchVersion: version.patchVersion,
            buildVersion: image.buildVersion,
            requirements: requirements
        )
    }
}
