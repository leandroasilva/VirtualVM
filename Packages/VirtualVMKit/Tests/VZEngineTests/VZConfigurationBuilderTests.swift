import Foundation
import Testing
import VMCore
@testable import VZEngine
import Virtualization

@MainActor
@Suite struct VZConfigurationBuilderTests {
    @Test func cpuCountStaysInTheRangeTheFrameworkAllows() {
        #expect(VZConfigurationBuilder.clampedCPUCount(0) == VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        #expect(VZConfigurationBuilder.clampedCPUCount(1 << 20) == VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        #expect(VZConfigurationBuilder.clampedCPUCount(4) == 4)
    }

    @Test func memorySizeIsClampedAndWholeMebibytes() {
        #expect(VZConfigurationBuilder.clampedMemorySize(1) == VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        // Four gibibytes, minus one byte: the frame rounds it down to the whole mebibyte below.
        let clamped = VZConfigurationBuilder.clampedMemorySize((4 << 30) - 1)
        #expect(clamped % (1 << 20) == 0)
        #expect(clamped == (4 << 30) - (1 << 20))
    }

    @Test func labelsAreTrimmedShortenedOrLeftOut() {
        #expect(VZConfigurationBuilder.label(from: "  Ubuntu  ") == "Ubuntu")
        #expect(VZConfigurationBuilder.label(from: "   ") == nil)
        let long = String(repeating: "x", count: 200)
        #expect(VZConfigurationBuilder.label(from: long)?.count == 64)
    }

    @Test func eachFamilyGetsItsOwnSharingTag() {
        #expect(VZConfigurationBuilder.sharedFoldersTag(for: .macOS) == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        #expect(VZConfigurationBuilder.sharedFoldersTag(for: .linux) == GuestIntegration.sharedFoldersTag)
    }

    @Test func sharedFoldersKeepTheirNamesApart() {
        let base = FileManager.default.temporaryDirectory
        let share = VZConfigurationBuilder.makeShare(for: [
            SharedFolder(name: "code", path: base.appending(path: "code").path, readOnly: false),
            SharedFolder(name: "code", path: base.appending(path: "other").path, readOnly: true),
            SharedFolder(name: "a/b", path: base.appending(path: "slash").path, readOnly: false),
        ])
        #expect(Set(share.directories.keys) == ["code", "code 2", "a-b"])
    }

    @Test func aDriveThatIsGoneIsRefusedByName() {
        let missing = RemovableImage(path: "/private/tmp/virtualvm-gone-\(UUID().uuidString)/ubuntu.iso", readOnly: true)
        #expect(throws: VZConfigurationBuilder.BuildError.self) {
            try VZConfigurationBuilder.makeRemovableDrive(for: missing)
        }
    }

    @Test func asifDrivesWaitForMacOS27() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "virtualvm-builder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "disk.asif")
        try Data("not really an image".utf8).write(to: file)
        let drive = RemovableImage(path: file.path, readOnly: false)
        if #unavailable(macOS 27.0) {
            #expect(throws: VZConfigurationBuilder.BuildError.self) {
                try VZConfigurationBuilder.makeRemovableDrive(for: drive)
            }
        } else {
            // On macOS 27 the refusal is gone; opening the fake file may still fail, but not on the version.
            #expect(throws: (any Error).self) {
                try VZConfigurationBuilder.makeRemovableDrive(for: drive)
            }
        }
    }
}
