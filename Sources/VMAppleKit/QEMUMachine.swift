import Foundation

public enum QEMUAccelerator: String, Sendable {
    case kvm
    case tcg
}

public struct QEMUOptions: Sendable {
    public var executable: String
    public var rom: String
    public var cpus: Int
    public var memoryGiB: Int
    public var bootArguments: String
    public var handoffAddresses: [UInt64] = []
    public var accelerator: QEMUAccelerator = .kvm
    public var vulkanICD: String?
    public var vncDisplay: String?
    /// iBoot reboots on its own, into recovery after a failed boot for one.
    /// A restore turns this off to see the restore OS finish.
    public var allowsReboot = true

    /// Waits 1 s, in picoseconds, for a CPU to answer the kernel debugger's
    /// cross-call. Apple's VM device tree sets `debug-ack-scale` to 0, which
    /// leaves 24,000,000 counter ticks: 24 ms at this VM's 1 GHz timebase.
    public static let debugAckTimeoutBootArguments = "ml-timeout-debug-ack=1000000000000 ml-timeout-debug-ack-scale=1"

    public init(executable: String, rom: String, cpus: Int, memoryGiB: Int, bootArguments: String) {
        self.executable = executable
        self.rom = rom
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.bootArguments = bootArguments
    }
}

public enum QEMUError: Error, CustomStringConvertible {
    case exited(Int32)
    case timeout(String)
    case refused(String)
    case alreadyRunning(String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path): "\(path) is already running; stop it first"
        case .exited(let status): "QEMU exited with \(status)"
        case .timeout(let what): "timed out waiting for \(what)"
        case .refused(let message): "QEMU refused: \(message)"
        }
    }
}

/// One run of QEMU's `vmapple` machine.
public final class QEMUMachine: @unchecked Sendable {
    public let machine: VirtualMachine
    private let options: QEMUOptions
    private let process = Process()
    private var signalSources: [DispatchSourceSignal] = []

    public init(machine: VirtualMachine, options: QEMUOptions) {
        self.machine = machine
        self.options = options
    }

    /// A vCPU must not move between core kinds, so the guest runs on the fastest.
    static func preferredCores() -> [Int] {
        HostCores.current().max { lhs, rhs in
            (maximumFrequency(lhs), lhs.cpus.count) < (maximumFrequency(rhs), rhs.cpus.count)
        }?.cpus ?? []
    }

    private static func maximumFrequency(_ kind: CoreKind) -> Int {
        guard let cpu = kind.cpus.first else { return 0 }
        let path = "/sys/devices/system/cpu/cpu\(cpu)/cpufreq/cpuinfo_max_freq"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Virtualization.framework's vendor configuration for a disk that does
    /// not encrypt inline: legacy features 3 (Patches/qemu 0017).
    private var rootDiskVendorData: String {
        machine.configuration.inlineEncryption == false ? ",vendor-legacy-features=3" : ""
    }

    var arguments: [String] {
        let id = String(machine.configuration.ecid, radix: 16, uppercase: true)
        let memory = "\(options.memoryGiB)G"
        let cpu = options.accelerator == .kvm ? "host,pmu=off,kvm-psci-version=1.1" : "max,pauth-impdef=on"
        let display = options.vncDisplay.map { "vnc=\($0)" } ?? "none"
        func path(_ url: URL) -> String { url.path }
        return [
            "-machine", "vmapple,accel=\(options.accelerator.rawValue),uuid=0x\(id),gfx-device=reims-vgpu-mmio,memory-backend=guestmem",
            "-object", "memory-backend-file,id=guestmem,size=\(memory),share=on,align=16384,mem-path=\(path(machine.guestMemory))",
            "-cpu", cpu,
            "-smp", String(options.cpus),
            "-m", memory,
            "-display", display,
            "-monitor", "none",
            // The console is logged to a file and also answers on a socket,
            // which `AccountProvisioner` types into.
            "-chardev", "socket,id=serial0,path=\(path(machine.serialSocket)),server=on,wait=off,logfile=\(path(machine.serialLog))",
            "-serial", "chardev:serial0",
            "-qmp", "unix:\(path(machine.qmpSocket)),server=on,wait=off",
            // A reset in place hangs the boot ROM, so a guest restart ends
            // QEMU and the caller starts a fresh one; see `guestRestarted`.
            "-action", options.allowsReboot ? "panic=pause,shutdown=poweroff,reboot=shutdown" : "panic=pause,shutdown=pause",
            "-msg", "timestamp=on",
            "-d", "guest_errors",
            "-D", path(machine.qemuLog),
            "-bios", options.rom,
            "-drive", "if=pflash,format=raw,file.filename=\(path(machine.aux)),file.locking=off",
            "-drive", "if=pflash,format=raw,file.filename=\(path(machine.disk)),file.locking=off",
            "-drive", "if=none,format=raw,file.filename=\(path(machine.aux)),file.locking=off,id=aux",
            "-device", "vmapple-virtio-blk-pci,variant=aux,drive=aux,share-rw=on",
            "-drive", "if=none,format=raw,file.filename=\(path(machine.disk)),file.locking=off,discard=unmap,id=root",
            "-device", "vmapple-virtio-blk-pci,variant=root,drive=root,share-rw=on" + rootDiskVendorData,
            "-chardev", "socket,id=vusb,path=\(path(machine.usbSocket)),server=on,wait=off",
            "-global", "vresearch-vusb.chardev=vusb",
            "-nic", "none",
        ] + (options.allowsReboot ? [] : ["-no-reboot"])
    }

    public func start() throws {
        if options.accelerator == .tcg && options.vulkanICD == nil {
            throw QEMUError.refused("TCG requires --vulkan-icd; use a software Vulkan driver on a GPU-less host")
        }
        if let icd = options.vulkanICD, !FileManager.default.fileExists(atPath: icd) {
            throw QEMUError.refused("Vulkan ICD does not exist: \(icd)")
        }
        // The disks are opened without locks, so a second QEMU on them would
        // write the same blocks. One left behind by a killed `boot` still
        // listens on its monitor socket.
        if let monitor = try? UnixSocket.connect(path: machine.qmpSocket.path) {
            monitor.close()
            throw QEMUError.alreadyRunning(machine.directory.path)
        }
        for url in [machine.serialLog, machine.serialSocket, machine.qemuLog, machine.qmpSocket, machine.usbSocket, machine.guestMemory] {
            try? FileManager.default.removeItem(at: url)
        }
        let cores = options.accelerator == .kvm ? Self.preferredCores() : []
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // VMAPPLE_QEMU_ARGS adds arguments for debugging, such as -gdb.
        let extra = ProcessInfo.processInfo.environment["VMAPPLE_QEMU_ARGS"]?
            .split(separator: " ").map(String.init) ?? []
        process.arguments = (cores.isEmpty ? [] : ["taskset", "-c", cores.map(String.init).joined(separator: ",")]) +
            [options.executable] + arguments + extra
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/lib/llvm-20/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["QEMU_VMAPPLE_HANDOFF"] = "1"
        environment["QEMU_VMAPPLE_PAC_DEFAULTS"] = "1"
        environment["QEMU_VMAPPLE_BOOT_ARGS"] = options.bootArguments
        let handoff = options.handoffAddresses.isEmpty ?
            (machine.configuration.handoffAddresses ?? []) : options.handoffAddresses
        if !handoff.isEmpty {
            environment["QEMU_VMAPPLE_HANDOFF_PC"] = handoff.map { "0x" + String($0, radix: 16) }.joined(separator: ",")
        }
        environment["REIMS_VGPU_WINDOW"] = "0"
        // Reims's zero-copy rails let the GPU write guest RAM it imported earlier.
        // On 27.2 the kernel had reused that RAM, and every boot panicked within a
        // minute of the language panel. Copying through a fresh page walk does not.
        for name in ["REIMS_VGPU_GUEST_IMPORT", "REIMS_VGPU_SHARED_TARGET"] where environment[name] == nil {
            environment[name] = "off"
        }
        // The wire watch sees the guest unwire a display buffer Reims still maps,
        // and the guard then stops Reims reading or writing its pages. Reims turns
        // both off by itself on a kernel whose layout it has not checked.
        for name in ["REIMS_VGPU_WIRE_WATCH", "REIMS_VGPU_WIRE_GUARD"] where environment[name] == nil {
            environment[name] = "1"
        }
        environment["VK_DRIVER_FILES"] = options.vulkanICD ?? "/usr/share/vulkan/icd.d/nvidia_icd.json"
        environment["TMPDIR"] = machine.directory.path
        environment["XDG_CACHE_HOME"] = machine.directory.appending(path: ".cache").path
        process.environment = environment
        process.currentDirectoryURL = machine.directory
        try process.run()
        endWithThisProcess()
    }

    /// QEMU does not notice its parent going, so a `boot` ended by a signal
    /// takes it along.
    private func endWithThisProcess() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [process] in
                Self.terminate(process)
                exit(128 + number)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Sends SIGTERM and, if QEMU still runs after `timeout`, SIGKILL. QEMU
    /// can take a minute to act on SIGTERM under a busy guest.
    static func terminate(_ process: Process, timeout: TimeInterval = 90) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    public var isRunning: Bool {
        process.isRunning
    }

    /// Whether the guest's last word before QEMU ended was a restart rather
    /// than a power-off, so the caller should boot it again.
    public var guestRestarted: Bool {
        serialLogText.map(Self.restarted(log:)) ?? false
    }

    /// Whether macOS panicked in this run. `start` clears the serial log, so
    /// it holds this run alone.
    public var guestPanicked: Bool {
        serialLogText.map { Self.lastPanic(in: $0) != nil } ?? false
    }

    private var serialLogText: String? {
        try? String(contentsOf: machine.serialLog, encoding: .utf8)
    }

    static func restarted(log: String) -> Bool {
        let off = log.range(of: "ApplePSCI - system off", options: .backwards)?.lowerBound
        let restart = [
            log.range(of: "ApplePSCI - system reset", options: .backwards)?.lowerBound,
            lastPanic(in: log),
        ].compactMap { $0 }.max()
        guard let restart else { return false }
        return off.map { restart > $0 } ?? true
    }

    /// The kernel's panic header, `panic(cpu 2 caller 0x…)`, can follow other
    /// console output on the same line.
    static func lastPanic(in log: String) -> String.Index? {
        log.range(of: "panic(cpu ", options: .backwards)?.lowerBound
    }

    public func waitUntilExit() {
        process.waitUntilExit()
    }

    /// Waits for QEMU to end, at most `timeout`. Returns whether it ended.
    public func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning {
            guard Date() < deadline else { return false }
            usleep(200_000)
        }
        return true
    }

    public func stop() {
        Self.terminate(process)
    }

    /// Shuts macOS down if it answers the power button, and switches off otherwise.
    public func shutDown(timeout: TimeInterval) {
        if let monitor = try? connectMonitor(timeout: 5) {
            try? monitor.powerDown(timeout: timeout)
            monitor.close()
        }
        stop()
    }

    public func connectUSB(timeout: TimeInterval) throws -> VUSBLink {
        try retry(timeout: timeout, what: "QEMU's USB socket") {
            try VUSBLink(socketPath: machine.usbSocket.path)
        }
    }

    public func connectMonitor(timeout: TimeInterval) throws -> QMPClient {
        try retry(timeout: timeout, what: "QEMU's monitor") {
            try QMPClient(socketPath: machine.qmpSocket.path)
        }
    }

    private func retry<Value>(timeout: TimeInterval, what: String, _ body: () throws -> Value) throws -> Value {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            do {
                return try body()
            } catch {
                guard process.isRunning else { throw QEMUError.exited(process.terminationStatus) }
                guard Date() < deadline else { throw QEMUError.timeout(what) }
                usleep(100_000)
            }
        }
    }
}

/// QEMU's monitor protocol. Pausing the VM resets the guest's USB controller,
/// so nothing here pauses it.
public final class QMPClient: @unchecked Sendable {
    private let socket: UnixSocket
    private var buffer: [UInt8] = []

    public init(socketPath: String) throws {
        socket = try UnixSocket.connect(path: socketPath)
        _ = try readLine()
        _ = try execute("qmp_capabilities")
    }

    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil) throws -> Any? {
        var message: [String: Any] = ["execute": command]
        if let arguments { message["arguments"] = arguments }
        try socket.write(Array(try JSONSerialization.data(withJSONObject: message)) + [0x0a])
        while true {
            let line = try readLine()
            guard let reply = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let result = reply["return"] { return result }
            if let error = reply["error"] as? [String: Any] {
                throw QEMUError.refused(error["desc"] as? String ?? "\(error)")
            }
        }
    }

    /// Shuts macOS down and waits for it. A guest that is switched off instead
    /// counts it as a failed boot, and LLB boots recovery after a few.
    /// macOS ignores QEMU's power button here, but takes Control-Option-
    /// Command-Power from the keyboard.
    public func powerDown(timeout: TimeInterval) throws {
        try press(keys: ["ctrl", "alt", "meta_l", "power"])
        let deadline = Date(timeIntervalSinceNow: timeout)
        do {
            while Date() < deadline {
                if try !isRunning() {
                    try? execute("quit")
                    return
                }
                sleep(1)
            }
        } catch is SocketError {
            return
        }
        throw QEMUError.timeout("the guest to shut down")
    }

    public func isRunning() throws -> Bool {
        let status = try execute("query-status") as? [String: Any]
        return status?["running"] as? Bool ?? false
    }

    public func screenshot(to path: String) throws {
        let dump = path + ".ppm"
        defer { try? FileManager.default.removeItem(atPath: dump) }
        try execute("screendump", arguments: ["filename": dump])
        let png = try PNG.convert(ppm: Array(try Data(contentsOf: URL(fileURLWithPath: dump))))
        try Data(png).write(to: URL(fileURLWithPath: path))
    }

    /// Moves the USB tablet and clicks. Coordinates are fractions of the screen.
    public func click(x: Double, y: Double) throws {
        func position(_ axis: String, _ value: Double) -> [String: Any] {
            ["type": "abs", "data": ["axis": axis, "value": Int(value * 32767)]]
        }
        func button(_ down: Bool) -> [String: Any] {
            ["type": "btn", "data": ["down": down, "button": "left"]]
        }
        try execute("input-send-event", arguments: ["events": [position("x", x), position("y", y)]])
        usleep(150_000)
        try execute("input-send-event", arguments: ["events": [button(true)]])
        usleep(80_000)
        try execute("input-send-event", arguments: ["events": [button(false)]])
    }

    /// QEMU key names, pressed together: `["shift", "a"]`.
    public func press(keys: [String]) throws {
        func event(_ key: String, down: Bool) -> [String: Any] {
            ["type": "key", "data": ["down": down, "key": ["type": "qcode", "data": key]]]
        }
        try execute("input-send-event", arguments: ["events": keys.map { event($0, down: true) }])
        usleep(60_000)
        try execute("input-send-event", arguments: ["events": keys.reversed().map { event($0, down: false) }])
        usleep(40_000)
    }

    public func close() {
        socket.close()
    }

    private func readLine() throws -> [UInt8] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            let bytes = try socket.read(upTo: 4096)
            if bytes.isEmpty { throw SocketError.closed }
            buffer += bytes
        }
    }
}
