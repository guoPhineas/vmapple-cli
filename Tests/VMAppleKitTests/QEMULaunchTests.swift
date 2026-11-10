//
//  QEMULaunchTests.swift
//  vmapple-cli
//
//  Created by Phineas Guo on 2026/11/10.
//

import Foundation
import Testing

@testable import VMAppleKit

@Suite struct QEMULaunchTests {
    private func machine(inlineEncryption: Bool? = false) -> VirtualMachine {
        VirtualMachine(
            directory: URL(fileURLWithPath: "/tmp/VM's Disk"),
            configuration: .init(ecid: 123, diskBytes: 64 << 30, handoffAddresses: [0xaca0_0000],
                                 installed: "13.6 (22G120)", image: nil, inlineEncryption: inlineEncryption)
        )
    }

    private func options(_ accelerator: QEMUAccelerator, bootArguments: String = "") -> QEMUOptions {
        QEMUOptions(executable: "qemu-system-aarch64", rom: "/dev/null", cpus: 4,
                    memoryGiB: 8, bootArguments: bootArguments, accelerator: accelerator)
    }

    @Test func hvfDoesNotRequireTheKVMDeviceExtensions() {
        let qemu = QEMUMachine(machine: machine(), options: options(.hvf))
        let arguments = qemu.arguments
        #expect(arguments.contains("hvf,kernel-irqchip=on"))
        #expect(arguments.contains("host"))
        #expect(!arguments.contains { $0.contains("kvm") || $0.contains("reims-vgpu-mmio") })
        #expect(!arguments.contains { $0.contains("vresearch-vusb") || $0.contains("id=vusb") })
        // This upstream device always supplies its own vendor capability and
        // has no vendor-legacy-features property.
        #expect(!arguments.contains { $0.contains("vendor-legacy-features") })
        #expect(!qemu.command.contains("taskset"))
    }

    @Test func hvfCanExposeTheRestoreUSBTransport() {
        var options = options(.hvf)
        options.usbDeviceMode = true
        let arguments = QEMUMachine(machine: machine(), options: options).arguments
        #expect(arguments.contains { $0.contains("vresearch-vusb.chardev=") })
        #expect(arguments.contains { $0.contains("id=vusb") })
        #expect(!arguments.contains { $0.contains("kvm") })
    }

    @Test func kvmKeepsItsDiskAndRestoreDeviceConfiguration() {
        let arguments = QEMUMachine(machine: machine(), options: options(.kvm)).arguments
        #expect(arguments.contains { $0.contains("accel=kvm") && $0.contains("gfx-device=reims-vgpu-mmio") })
        #expect(arguments.contains("host,pmu=off,kvm-psci-version=1.1"))
        #expect(arguments.contains { $0.contains("variant=root") && $0.contains("vendor-legacy-features=3") })
        #expect(arguments.contains { $0.contains("vresearch-vusb.chardev=") })
        let encrypted = QEMUMachine(machine: machine(inlineEncryption: nil), options: options(.kvm)).arguments
        #expect(!encrypted.contains { $0.contains("vendor-legacy-features") })
    }

    @Test func hvfDoesNotInheritLinuxIntegrationSettings() {
        var options = options(.hvf)
        options.showsWindow = true
        let qemu = QEMUMachine(machine: machine(), options: options)
        let environment = qemu.environment(inheriting: [
            "QEMU_VMAPPLE_HANDOFF": "1", "QEMU_VMAPPLE_PAC_DEFAULTS": "1",
            "QEMU_VMAPPLE_BOOT_ARGS": "-s", "VK_DRIVER_FILES": "/linux/nvidia.json",
            "PATH": "/usr/bin:/bin",
        ])
        #expect(!environment.keys.contains { $0.hasPrefix("QEMU_VMAPPLE_") })
        #expect(environment["VK_DRIVER_FILES"] == nil)
        #expect(environment["REIMS_VGPU_WINDOW"] == "1")
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(environment["REIMS_VGPU_WIRE_GUARD"] == nil)
    }

    @Test func kvmStillGetsItsHandoffAndMemoryGuards() {
        let environment = QEMUMachine(machine: machine(), options: options(.kvm, bootArguments: "-v"))
            .environment(inheriting: [:])
        #expect(environment["QEMU_VMAPPLE_BOOT_ARGS"] == "-v")
        #expect(environment["QEMU_VMAPPLE_HANDOFF_PC"] == "0xaca00000")
        #expect(environment["REIMS_VGPU_GUEST_IMPORT"] == "off")
        #expect(environment["REIMS_VGPU_WIRE_GUARD"] == "1")
    }

    @Test func previewQuotesPathsWithSpacesAndApostrophes() {
        let command = QEMUMachine(machine: machine(), options: options(.hvf)).launchDescription
        #expect(command.hasPrefix("cd '/tmp/VM'\\''s Disk' &&\n"))
        #expect(command.contains("'hvf,kernel-irqchip=on'"))
        #expect(!command.contains("VMAPPLE_PASSWORD="))
    }

    @Test func hvfRefusesSettingsItCannotApply() {
        #expect(throws: QEMUError.self) {
            try QEMUMachine(machine: machine(), options: options(.hvf, bootArguments: "-s")).validate()
        }
        #expect(throws: QEMUError.self) {
            try QEMUMachine(machine: machine(inlineEncryption: true), options: options(.hvf)).validate()
        }
    }

    @Test func restoreValidatesQEMUBeforeResettingTheDisks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hvf-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest: [String: Any] = ["BuildIdentities": [[
            "Info": ["DeviceClass": "vma2macosap", "Variant": "Erase Install", "RestoreBehavior": "Erase"],
            "Manifest": [String: Any](),
        ]]]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: directory.appending(path: "BuildManifest.plist"))
        let machine = VirtualMachine(directory: directory, configuration: machine().configuration)
        let sentinel = Data("keep this installed disk".utf8)
        try sentinel.write(to: machine.disk)
        try sentinel.write(to: machine.aux)
        var options = options(.hvf)
        options.executable = "/does/not/exist"
        let restore = RestoreSession(machine: machine, firmware: try Firmware(directory: directory),
                                     options: options, idevicerestore: "/does/not/exist", log: { _ in })
        #expect(throws: QEMUError.self) { try restore.run() }
        #expect(try Data(contentsOf: machine.disk) == sentinel)
        #expect(try Data(contentsOf: machine.aux) == sentinel)
    }

    @Test func qemuInspectionUsesHelpOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "qemu-inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "QEMU with spaces")
        let script = """
        #!/bin/sh
        case "$1:$2" in
          -machine:help) echo 'vmapple  Virtual Mac' ;;
          -accel:help) printf 'Accelerators supported:\\nhvf\\ntcg\\n' ;;
          -device:apple-gfx-mmio,help) echo 'apple-gfx-mmio options:' ;;
          *) exit 99 ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(HostChecks.qemu(executable: executable.path, accelerator: .hvf).state == .ok)
        #expect(HostChecks.qemu(executable: executable.path, accelerator: .kvm).state == .missing)
    }
}
