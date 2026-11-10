import ArgumentParser
import Foundation
import VMAppleKit

@main
struct VMAppleCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmapple-cli",
        abstract: "Virtual Macs with QEMU: KVM on arm64 Linux, HVF on Apple silicon macOS.",
        subcommands: [Doctor.self, Probe.self, Create.self, Pull.self, Restore.self, Account.self, Boot.self, Screenshot.self, Click.self, Press.self, IBoot.self, Stop.self]
    )
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check this host.")

    @Option(help: "QEMU executable to inspect without starting a VM.")
    var qemu = ProcessInfo.processInfo.environment["VMAPPLE_QEMU"] ?? "qemu-system-aarch64"

    func run() throws {
        let checks = HostChecks.all() + [HostChecks.qemu(executable: qemu)]
        for check in checks {
            print("\(check.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))\(check.name.padding(toLength: 10, withPad: " ", startingAt: 0))\(check.detail)")
        }
        if checks.contains(where: { $0.state != .ok }) {
            throw ExitCode.failure
        }
    }
}

// MARK: - probe

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a throwaway KVM guest on each kind of core.")

    func run() throws {
        guard QEMUAccelerator.host == .kvm else {
            throw ValidationError("probe runs a Linux KVM guest; use doctor to check an Apple silicon host")
        }
        let kinds = HostCores.current()
        guard !kinds.isEmpty else {
            print("no CPU parts in /proc/cpuinfo")
            throw ExitCode.failure
        }
        var failed = false
        for kind in kinds {
            guard let cpu = kind.cpus.first else { continue }
            print("\(kind.part) (cpu \(cpu), \(kind.cpus.count) cores)")
            do {
                let result = try KVMProbe.run(cpu: cpu)
                line("16K stage 1", result.mmu16K, "TGran16=\(result.tgran16)")
                line("VMApple hypercalls", result.hypercallForwarded, "forwarded and resumed")
                line("PSCI 1.1", result.psci11, "")
                line("pointer authentication", result.pointerAuthentication, "EL0 and EL1 share keys: \(!result.appleKeyRegisters)")
                print("  IPA \(result.ipaBits) bits, PARange \(result.paRange), counter \(result.counterFrequency) Hz")
                failed = failed || !result.passed
            } catch {
                print("  failed: \(error)")
                failed = true
            }
        }
        if failed {
            throw ExitCode.failure
        }
    }

    private func line(_ name: String, _ passed: Bool, _ detail: String) {
        print("  \(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

@Sendable func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

// MARK: - machine options

struct MachineOptions: ParsableArguments {
    @Option(help: "Patched QEMU: the KVM build on Linux or the Reims/HVF build on macOS.")
    var qemu = ProcessInfo.processInfo.environment["VMAPPLE_QEMU"] ?? "qemu-system-aarch64"

    @Option(help: "Boot ROM. OpenAVB on Linux; an explicitly supplied HVF-compatible ROM on macOS.")
    var rom = ProcessInfo.processInfo.environment["VMAPPLE_ROM"] ?? (QEMUAccelerator.host == .kvm ? "OpenAVB.bin" : "")

    @Option(help: "Virtual CPUs. KVM runs them on the host's fastest core kind.")
    var cpus = 4

    @Option(help: "Guest memory in GiB.")
    var memory = 8

    @Flag(help: "Open the Reims guest display window.")
    var window = false

    @Flag(help: "Expose the virtual USB link for DFU and iBoot recovery.")
    var usb = false

    func options(bootArguments: String) -> QEMUOptions {
        var options = QEMUOptions(executable: qemu, rom: rom, cpus: cpus, memoryGiB: memory, bootArguments: bootArguments)
        options.showsWindow = window
        options.usbDeviceMode = usb || options.accelerator == .kvm
        return options
    }
}

// MARK: - create

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a virtual Mac with blank disks.")

    @Argument(help: "The VM's directory.")
    var path: String

    @Option(help: "Disk size in GiB.")
    var disk: UInt64 = 64

    func run() throws {
        let machine = try VirtualMachine.create(at: URL(fileURLWithPath: path), diskGiB: disk,
                                                inlineEncryption: QEMUAccelerator.host == .hvf ? false : nil)
        print("Created \(machine.directory.path), ECID \(String(machine.configuration.ecid, radix: 16))")
    }
}

// MARK: - pull

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a virtual Mac from a Tart image in an OCI registry.",
        discussion: "Takes the images Tart, macos-image and mini-control publish, with zstd or LZ4 disk layers. The image's own account and settings come with it, so no restore or account step is needed."
    )

    @Argument(help: "The image, like ghcr.io/minimillionaire/macos-golden-gate-base:27.2.")
    var image: String

    @Argument(help: "The VM's directory. It must not exist yet.")
    var path: String

    @Option(help: "Disk layers to download at once.")
    var jobs = 4

    func run() throws {
        let machine = try ImagePull.run(
            try OCIReference(image),
            to: URL(fileURLWithPath: path),
            jobs: jobs,
            log: say
        )
        let installed = machine.configuration.installed.map { "macOS \($0), " } ?? ""
        say("Created \(machine.directory.path): \(installed)ECID \(String(machine.configuration.ecid, radix: 16))")
    }
}

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install macOS from an IPSW, with no Mac.")

    @Argument(help: "The VM's directory.")
    var path: String

    @Argument(help: "A restore IPSW, or a directory it was extracted to.")
    var firmware: String

    @Option(help: "idevicerestore built with Patches/idevicerestore.")
    var idevicerestore = "idevicerestore"

    @OptionGroup var machineOptions: MachineOptions

    func run() throws {
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let url = URL(fileURLWithPath: firmware)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: firmware, isDirectory: &isDirectory)
        let image = isDirectory.boolValue ? try Firmware(directory: url) : try Firmware.prepare(ipsw: url)
        say("Restoring macOS \(image.version) (\(image.build))")
        try RestoreSession(
            machine: machine,
            firmware: image,
            options: machineOptions.options(bootArguments: ""),
            idevicerestore: idevicerestore,
            log: say
        ).run()
    }
}

// MARK: - boot

struct Account: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create an administrator account and skip Setup Assistant.",
        discussion: "Boots the guest single-user and types the commands on its serial console. The password comes from VMAPPLE_PASSWORD."
    )

    @Argument(help: "The VM's directory.")
    var path: String

    @Option(help: "Short user name.")
    var user: String

    @Option(help: "Full name. The short name by default.")
    var fullName: String?

    @OptionGroup var machineOptions: MachineOptions

    func run() throws {
        guard QEMUAccelerator.host == .kvm else {
            throw ValidationError("account currently needs Linux/KVM single-user boot support")
        }
        guard let password = ProcessInfo.processInfo.environment["VMAPPLE_PASSWORD"], !password.isEmpty else {
            throw ValidationError("Set VMAPPLE_PASSWORD to the account's password.")
        }
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let provisioner = AccountProvisioner(
            machine: machine,
            options: machineOptions.options(bootArguments: ""),
            log: { print($0) }
        )
        try provisioner.run(user: user, fullName: fullName ?? user, password: password)
    }
}

struct Boot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Boot an installed virtual Mac.")

    @Argument(help: "The VM's directory.")
    var path: String

    @Option(parsing: .unconditional, help: "Kernel boot arguments.")
    var bootArgs = QEMUOptions.defaultBootArguments

    @Flag(help: "Print the launch command without starting QEMU or modifying the VM.")
    var dryRun = false

    @Option(help: "Stop after this many seconds. By default, runs until the guest stops.")
    var seconds: Int?

    @Flag(help: "After a kernel panic, keep the guest's memory and serial log beside the VM before restarting it.")
    var keepPanicMemory = false

    @OptionGroup var machineOptions: MachineOptions

    func run() throws {
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let options = machineOptions.options(bootArguments: bootArgs)
        if dryRun {
            print(QEMUMachine(machine: machine, options: options).launchDescription)
            return
        }
        if let seconds {
            let qemu = QEMUMachine(machine: machine, options: options)
            try qemu.start()
            if !qemu.waitUntilExit(timeout: TimeInterval(seconds)) {
                qemu.shutDown(timeout: 120)
            }
            return
        }
        // A guest restart ends QEMU; boot the guest again, keeping the last
        // run's serial log beside the new one.
        while true {
            let qemu = QEMUMachine(machine: machine, options: options)
            try qemu.start()
            qemu.waitUntilExit()
            guard qemu.guestRestarted else { return }
            if keepPanicMemory && qemu.guestPanicked {
                try keepPanic(of: machine)
            }
            let previous = machine.directory.appending(path: "serial.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: machine.serialLog, to: previous)
            print("The guest restarted; starting it again")
        }
    }

    /// Moves the panicked guest's RAM aside, so the next run's fresh file
    /// does not replace it, and copies its serial log next to it.
    private func keepPanic(of machine: VirtualMachine) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let name = "panic-\(formatter.string(from: Date()))"
        let memory = machine.directory.appending(path: "\(name).ram")
        let serialLog = machine.directory.appending(path: "\(name).serial.log")
        try FileManager.default.moveItem(at: machine.guestMemory, to: memory)
        try FileManager.default.copyItem(at: machine.serialLog, to: serialLog)
        print("The guest panicked; kept its memory in \(memory.path) and its serial log in \(serialLog.path)")
    }
}

// MARK: - screenshot

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a running guest's screen as a PNG.")

    @Argument(help: "The VM's directory.")
    var path: String

    @Argument(help: "The PNG to write.")
    var output: String

    func run() throws {
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let monitor = try QMPClient(socketPath: machine.qmpSocket.path)
        defer { monitor.close() }
        try monitor.screenshot(to: URL(fileURLWithPath: output).path)
    }
}

// MARK: - input

struct Click: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Click on a running guest's screen.")

    @Argument(help: "The VM's directory.")
    var path: String

    @Argument(help: "Horizontal position, 0 to 1.")
    var x: Double

    @Argument(help: "Vertical position, 0 to 1.")
    var y: Double

    func run() throws {
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let monitor = try QMPClient(socketPath: machine.qmpSocket.path)
        defer { monitor.close() }
        try monitor.click(x: x, y: y)
    }
}

struct Press: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Press keys on a running guest, as QEMU key names.")

    @Argument(help: "The VM's directory.")
    var path: String

    @Argument(help: "Chords, each joined with +, like shift+a ret.")
    var chords: [String]

    func run() throws {
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let monitor = try QMPClient(socketPath: machine.qmpSocket.path)
        defer { monitor.close() }
        for chord in chords {
            try monitor.press(keys: chord.split(separator: "+").map(String.init))
        }
    }
}

// MARK: - iBoot

struct IBoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iboot",
        abstract: "Run commands at a running guest's iBoot recovery prompt."
    )

    @Argument(help: "The VM's directory.")
    var path: String

    @Argument(help: "Commands, like \"getenv auto-boot\" or reboot.")
    var commands: [String]

    func run() throws {
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let link = try VUSBLink(socketPath: machine.usbSocket.path)
        defer { link.close() }
        let device = try link.waitForDevice([USBProduct.recovery], timeout: 30)
        for command in commands {
            let reply = try IBootPrompt.run(command, on: device)
            say(reply.isEmpty ? "\(command): ok" : "\(command): \(reply)")
        }
    }
}

// MARK: - stop

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shut a running guest down cleanly.")

    @Argument(help: "The VM's directory.")
    var path: String

    @Option(help: "Seconds to wait for macOS to finish.")
    var timeout = 120

    func run() throws {
        let machine = try VirtualMachine.open(at: URL(fileURLWithPath: path))
        let monitor = try QMPClient(socketPath: machine.qmpSocket.path)
        defer { monitor.close() }
        try monitor.powerDown(timeout: TimeInterval(timeout))
    }
}
