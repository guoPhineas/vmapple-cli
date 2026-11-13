//
//  TCGOptionsTests.swift
//  vmapple-cli
//
//  Created by Phineas Guo on 2026/11/13.
//

import Foundation
import Testing
@testable import VMAppleKit

@Suite struct TCGOptionsTests {
    @Test func tcgUsesAnEmulatedArmCPUAndVNCConsole() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vm-\(UInt32.random(in: 0 ... .max))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try VirtualMachine.create(at: directory, diskGiB: 1)
        var options = QEMUOptions(executable: "qemu-system-aarch64", rom: "OpenAVB.bin", cpus: 2, memoryGiB: 4, bootArguments: "")
        options.accelerator = .tcg
        options.vulkanICD = "/usr/share/vulkan/icd.d/lvp_icd.x86_64.json"
        options.vncDisplay = "127.0.0.1:0"

        let arguments = QEMUMachine(machine: machine, options: options).arguments
        #expect(arguments.contains { $0.contains("vmapple,accel=tcg,") })
        #expect(arguments.contains("max,pauth-impdef=on"))
        #expect(arguments.contains("vnc=127.0.0.1:0"))
        #expect(!arguments.contains { $0.contains("kvm-psci-version") })
    }

    @Test func tcgRequiresAnExplicitVulkanDriver() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vm-\(UInt32.random(in: 0 ... .max))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try VirtualMachine.create(at: directory, diskGiB: 1)
        var options = QEMUOptions(executable: "/bin/false", rom: "", cpus: 1, memoryGiB: 1, bootArguments: "")
        options.accelerator = .tcg

        #expect(throws: QEMUError.self) {
            try QEMUMachine(machine: machine, options: options).start()
        }
        #expect(FileManager.default.fileExists(atPath: machine.disk.path))
    }

    @Test func tcgDoctorDoesNotRequireKVMOrHostPAC() {
        let checks = HostChecks.all(accelerator: .tcg)
        #expect(!checks.contains { $0.name == "kvm" || $0.name == "pac" })
        #expect(checks.first { $0.name == "vulkan" }?.state == .missing)
    }
}
