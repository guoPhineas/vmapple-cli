import Foundation

public enum ProvisionError: Error, CustomStringConvertible {
    case noPrompt
    case commandFailed(String, String)
    case badName(String)
    case badPassword

    public var description: String {
        switch self {
        case .noPrompt: "the single-user shell never prompted"
        case .commandFailed(let command, let status): "\(command) ended with \(status)"
        case .badName(let name): "\(name) is not a valid short user name"
        case .badPassword: "the password must not contain a single quote or a line break"
        }
    }
}

/// Creates an administrator account on an installed guest without Setup
/// Assistant: a single-user boot, driven over the serial console. On 14 and
/// later the Data volume is encrypted, so it cannot be written from the host.
/// The commands follow aquarat's macOS 26 account step
/// (experiment-macOS-arm64-on-asahi-linux-arm64, images/host/create-account.sh).
public final class AccountProvisioner {
    private let machine: VirtualMachine
    private let options: QEMUOptions
    private let log: (String) -> Void
    private var console: UnixSocket?
    private var output: [UInt8] = []
    private var marker = 0

    public init(machine: VirtualMachine, options: QEMUOptions, log: @escaping (String) -> Void) {
        var options = options
        options.bootArguments = "-s -v serial=11 debug=0x14c \(QEMUOptions.debugAckTimeoutBootArguments)"
        // `reboot` at the end then ends QEMU.
        options.allowsReboot = false
        self.machine = machine
        self.options = options
        self.log = log
    }

    public func run(user: String, fullName: String, password: String) throws {
        guard options.accelerator == .kvm else {
            throw QEMUError.refused("account provisioning needs single-user boot arguments, which the HVF QEMU profile does not support")
        }
        guard user.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) != nil else {
            throw ProvisionError.badName(user)
        }
        guard !password.contains("'"), !password.contains("\n") else { throw ProvisionError.badPassword }
        let qemu = QEMUMachine(machine: machine, options: options)
        try qemu.start()
        defer {
            console?.close()
            qemu.stop()
            scrub(password)
        }
        console = try connect(qemu)
        log("Waiting for the single-user shell")
        try waitForPrompt(timeout: 420)

        let resources = "/System/Library/Filesystems/apfs.fs/Contents/Resources"
        log("Mounting the Data volume")
        try execute("\(resources)/apfs_boot_util 1; \(resources)/apfs_boot_util 2; test -d /private/var/db/dslocal/nodes/Default", timeout: 180)
        log("Starting directory services")
        try execute("launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.opendirectoryd.plist; sleep 3; launchctl list | grep -q opendirectoryd", timeout: 90)
        log("Creating \(user)")
        let home = "/Users/\(user)"
        try execute([
            "dscl . -create \(home)",
            "dscl . -create \(home) UniqueID 501",
            "dscl . -create \(home) PrimaryGroupID 20",
            "dscl . -create \(home) UserShell /bin/zsh",
            "dscl . -create \(home) RealName '\(fullName.replacingOccurrences(of: "'", with: ""))'",
            "dscl . -create \(home) NFSHomeDirectory \(home)",
            "dseditgroup -o edit -a \(user) -t user admin",
        ].joined(separator: " && "), timeout: 90)
        try execute("dscl . -passwd \(home) '\(password)'", timeout: 60, quiet: true)
        scrub(password)
        log("Skipping Setup Assistant")
        try execute("touch /private/var/db/.AppleSetupDone && sync", timeout: 60)
        try send("reboot\n")
        let deadline = Date(timeIntervalSinceNow: 180)
        while qemu.isRunning, Date() < deadline {
            sleep(1)
        }
        log("Account \(user) created")
    }

    // MARK: - Console

    private func connect(_ qemu: QEMUMachine) throws -> UnixSocket {
        let deadline = Date(timeIntervalSinceNow: 30)
        while true {
            if let socket = try? UnixSocket.connect(path: machine.serialSocket.path) {
                return socket
            }
            guard qemu.isRunning else { throw QEMUError.exited(1) }
            guard Date() < deadline else { throw QEMUError.timeout("the serial console") }
            usleep(200_000)
        }
    }

    private func send(_ text: String) throws {
        try console?.write(Array(text.utf8))
    }

    /// Reads until `pattern` matches what arrived since `start`, and returns that text.
    private func read(until pattern: String, from start: Int, timeout: TimeInterval) throws -> String? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let text = String(decoding: output[start...], as: UTF8.self)
            if text.range(of: pattern, options: .regularExpression) != nil {
                return text
            }
            guard let console else { return nil }
            output += try console.read(upTo: 4096, timeout: 1)
        }
        return nil
    }

    private func waitForPrompt(timeout: TimeInterval) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        // A key that reaches iBoot's console stops the autoboot, so nothing is
        // typed until the kernel is running.
        guard try read(until: "Darwin Kernel Version", from: 0, timeout: timeout) != nil else {
            throw ProvisionError.noPrompt
        }
        if try read(until: "(root#|sh-[0-9.]+#|# )\\s*$", from: 0, timeout: 120) != nil {
            return
        }
        while Date() < deadline {
            let start = output.count
            try send("\n")
            if try read(until: "(root#|sh-[0-9.]+#|# )\\s*$", from: start, timeout: 10) != nil {
                return
            }
        }
        throw ProvisionError.noPrompt
    }

    /// Runs one shell command and throws unless it exits 0.
    private func execute(_ command: String, timeout: TimeInterval, quiet: Bool = false) throws {
        marker += 1
        let tag = "__DONE_\(marker)__"
        let start = output.count
        try send("\(command); echo \(tag)$?\n")
        guard let text = try read(until: "\(tag)[0-9]+", from: start, timeout: timeout),
              let range = text.range(of: "\(tag)[0-9]+", options: .regularExpression) else {
            throw ProvisionError.commandFailed(quiet ? "a hidden command" : command, "no answer")
        }
        let status = String(text[range].dropFirst(tag.count))
        guard status == "0" else {
            throw ProvisionError.commandFailed(quiet ? "a hidden command" : command, "status \(status)")
        }
    }

    /// The console echoes what is typed, password included; overwrite it in
    /// the log, in place, so QEMU's write offset stays valid.
    private func scrub(_ secret: String) {
        guard !secret.isEmpty,
              let handle = try? FileHandle(forUpdating: machine.serialLog),
              let data = try? handle.readToEnd() else { return }
        defer { try? handle.close() }
        let needle = Data(secret.utf8)
        var copy = data
        var searchStart = copy.startIndex
        var changed = false
        while let range = copy.range(of: needle, in: searchStart..<copy.endIndex) {
            copy.replaceSubrange(range, with: Data(repeating: UInt8(ascii: "X"), count: needle.count))
            searchStart = range.upperBound
            changed = true
        }
        guard changed else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: copy)
    }
}
