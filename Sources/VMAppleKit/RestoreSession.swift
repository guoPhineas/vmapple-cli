import Foundation

public enum RestoreError: Error, CustomStringConvertible {
    case noNonce(String)
    case nonceChanged
    case restoreFailed(Int32)

    public var description: String {
        switch self {
        case .noNonce(let text): "iBoot reported no nonce: \(text)"
        case .nonceChanged: "the nonce changed between iBSS and iBEC"
        case .restoreFailed(let status): "idevicerestore exited with \(status)"
        }
    }
}

/// Blank disks to an installed macOS, with no Mac: DFU, iBSS, iBEC and the
/// restore OS are driven here, and idevicerestore talks to `restored`.
public final class RestoreSession: @unchecked Sendable {
    private let machine: VirtualMachine
    private let firmware: Firmware
    private let qemu: QEMUMachine
    private let idevicerestore: String
    private let log: @Sendable (String) -> Void
    private var ecid: UInt64 { machine.configuration.ecid }

    /// `-progress` shows the restore on screen, and `-restore` runs `restored`.
    public static let bootArguments = "rd=md0 nand-enable-reformat=1 -v -restore serial=11 debug=0x14c"

    public init(
        machine: VirtualMachine,
        firmware: Firmware,
        options: QEMUOptions,
        idevicerestore: String,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.machine = machine
        self.firmware = firmware
        var options = options
        // HVF receives these through iBEC's setenv command below; its QEMU
        // build does not implement the KVM boot-argument environment hook.
        options.bootArguments = options.accelerator == .kvm ? Self.bootArguments : ""
        options.usbDeviceMode = true
        options.handoffAddresses = (try? firmware.handoffAddresses(for: "iBEC")) ?? []
        options.allowsReboot = false
        qemu = QEMUMachine(machine: machine, options: options)
        self.idevicerestore = idevicerestore
        self.log = log
    }

    public func run() throws {
        // Refuse an incompatible executable before erasing either disk.
        try qemu.validate()
        try machine.resetDisks()
        try qemu.start()
        defer { qemu.stop() }
        let link = try qemu.connectUSB(timeout: 30)
        defer { link.close() }

        log("Waiting for DFU")
        let dfu = try link.waitForDevice([USBProduct.dfu], timeout: 120)
        try sendIBSS(to: dfu)

        log("Waiting for iBSS")
        let stage1 = try link.waitForDevice([USBProduct.recovery], timeout: 120)
        let nonces = try readNonces(stage1)
        let ticket = try Ticket.request(firmware: firmware, ecid: ecid, nonces: nonces)
        try Data(ticket).write(to: machine.ticket)
        let bootingStage = try sendIBEC(to: stage1, nonces: nonces, ticket: ticket)
        try link.waitForStageChange(after: bootingStage, timeout: 60)

        log("Waiting for iBEC")
        let stage2 = try link.waitForDevice([USBProduct.recovery], timeout: 120)
        guard try readNonces(stage2) == nonces else { throw RestoreError.nonceChanged }
        let bootStage = try bootRestoreOS(on: stage2, ticket: ticket)

        log("Waiting for the restore OS")
        try runRestore(link: link, bootStage: bootStage, nonces: nonces)
        try waitForReset()
        var configuration = machine.configuration
        configuration.handoffAddresses = try firmware.handoffAddresses(for: "iBoot")
        configuration.installed = "\(firmware.version) (\(firmware.build))"
        try machine.save(configuration)
    }

    // MARK: - Stages

    private func sendIBSS(to device: USBDevice) throws {
        let image = try firmware.load("iBSS")
        let description = try firmware.iBSSDescription()
        // The ROM reads this ticket's shape and does not check it, so any nonce will do.
        let placeholder = DeviceNonces(ap: [UInt8](repeating: 0, count: 32), sep: [UInt8](repeating: 0xaa, count: 20))
        let ticket = try Ticket.request(firmware: firmware, ecid: ecid, nonces: placeholder)
        log("Sending iBSS")
        try DFU.send(image: IMG4.wrap(im4p: image, ticket: ticket), description: description, to: device)
        do {
            try device.link.reset(timeout: 5)
        } catch USBError.unplugged {
        } catch is USBError {
        }
    }

    private func readNonces(_ device: USBDevice) throws -> DeviceNonces {
        let text = try device.string(at: 1)
        guard let nonces = DeviceNonces(productString: text) else { throw RestoreError.noNonce(text) }
        return nonces
    }

    /// iBEC will not start until an empty local policy has gone first, with a
    /// ticket of its own that names the AP ticket. Returns the stage iBSS is in.
    private func sendIBEC(to device: USBDevice, nonces: DeviceNonces, ticket: [UInt8]) throws -> Int {
        let policyTicket = try Ticket.requestLocalPolicy(
            firmware: firmware,
            ecid: ecid,
            nonces: nonces,
            apTicket: ticket
        )
        try device.setConfiguration(1)
        try device.setInterface(1, alternate: 1)
        log("Sending the local policy and iBEC")
        try send(IMG4.wrap(im4p: IMG4.emptyLocalPolicy, ticket: policyTicket), to: device)
        try command("lpolrestore", on: device)
        try? command("setenv auto-boot false", on: device)
        try send(IMG4.wrap(im4p: try firmware.load("iBEC"), ticket: ticket), to: device)
        sleep(1)
        let stage = device.link.currentStage
        try command("go", request: 1, on: device)
        return stage
    }

    /// Returns the stage iBEC is in, because a USB reset would stop it mid-boot.
    private func bootRestoreOS(on device: USBDevice, ticket: [UInt8]) throws -> Int {
        try device.setConfiguration(1)
        try device.setInterface(1, alternate: 1)
        try? command("setenv auto-boot false", on: device)
        for component in firmware.firmwareComponents {
            log("Sending \(component)")
            try send(try stitched(component, ticket: ticket), to: device)
            try command("firmware", on: device)
        }
        log("Sending the ramdisk, device tree and kernel")
        try send(try stitched("RestoreRamDisk", ticket: ticket), to: device)
        try command("ramdisk", on: device)
        try send(try stitched("RestoreDeviceTree", ticket: ticket), to: device)
        try command("devicetree", on: device)
        try send(try stitched("RestoreKernelCache", ticket: ticket), to: device)
        try command("setenv boot-args \(Self.bootArguments)", on: device)
        let stage = device.link.currentStage
        try command("bootx", request: 1, on: device)
        return stage
    }

    private func stitched(_ component: String, ticket: [UInt8]) throws -> [UInt8] {
        guard let tag = Tag.restoreComponents[component] else { throw FirmwareError.missing("a tag for \(component)") }
        return IMG4.wrap(im4p: try IMG4.retagged(im4p: try firmware.load(component), tag: tag), ticket: ticket)
    }

    private func runRestore(link: VUSBLink, bootStage: Int, nonces: DeviceNonces) throws {
        try link.waitForStageChange(after: bootStage, timeout: 300)
        let server = try USBMuxServer(socketPath: machine.muxSocket.path, log: log)
        defer { server.close() }
        // The restore OS brings its controller up more than once.
        let serving = Thread { [log] in
            while !server.isClosed {
                do {
                    let device = try link.waitForDevice([USBProduct.restore], timeout: 600)
                    log("Restore OS is up")
                    try server.serve(device: device)
                } catch {
                    log("USB: \(error)")
                }
            }
        }
        serving.name = "usbmux-device"
        serving.start()
        try server.waitForDevice(timeout: 180)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // idevicerestore also creates a timestamped log in its working directory.
        process.currentDirectoryURL = machine.directory
        process.arguments = [
            idevicerestore.contains("/") ? URL(fileURLWithPath: idevicerestore).path : idevicerestore,
            "--erase", "--no-input", "--restore-mode",
            "--ticket", machine.ticket.path,
            "--ecid", "0x" + String(ecid, radix: 16),
            firmware.directory.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["USBMUXD_SOCKET_ADDRESS"] = "UNIX:" + machine.muxSocket.path
        environment["VMAPPLE_AP_NONCE"] = nonces.ap.map { String(format: "%02X", $0) }.joined()
        environment["VMAPPLE_SEP_NONCE"] = nonces.sep.map { String(format: "%02X", $0) }.joined()
        process.environment = environment
        let output = FileHandle(forWritingAtPath: restoreLog.path) ?? {
            FileManager.default.createFile(atPath: restoreLog.path, contents: nil)
            return FileHandle(forWritingAtPath: restoreLog.path)!
        }()
        try output.truncate(atOffset: 0)
        process.standardOutput = output
        process.standardError = output
        log("Restoring with idevicerestore; see \(restoreLog.path)")
        try process.run()
        process.waitUntilExit()
        try output.close()
        guard process.terminationStatus == 0 else { throw RestoreError.restoreFailed(process.terminationStatus) }
    }

    private var restoreLog: URL {
        machine.directory.appending(path: "restore.log")
    }

    /// The restore OS resets the machine once it has finished writing.
    private func waitForReset() throws {
        let monitor = try qemu.connectMonitor(timeout: 10)
        defer { monitor.close() }
        let deadline = Date(timeIntervalSinceNow: 180)
        while Date() < deadline {
            if try !monitor.isRunning() {
                log("Restore finished")
                return
            }
            sleep(2)
        }
        throw QEMUError.timeout("the restore OS to reset after installing macOS")
    }

    // MARK: - iBoot

    /// iBoot's interfaces hold only 512 byte packets.
    private func send(_ bytes: [UInt8], to device: USBDevice) throws {
        try device.controlOut(type: 0x41, request: 0, value: 0, index: 0)
        for start in stride(from: 0, to: bytes.count, by: 512) {
            let end = min(start + 512, bytes.count)
            try device.link.bulkOut(endpoint: 4, data: Array(bytes[start..<end]), timeout: 30)
        }
    }

    private func command(_ text: String, request: UInt8 = 0, on device: USBDevice) throws {
        try IBootPrompt.send(text, request: request, on: device)
    }
}

/// iBoot's recovery prompt over USB.
public enum IBootPrompt {
    public static func send(_ text: String, request: UInt8 = 0, on device: USBDevice) throws {
        try device.controlOut(type: 0x40, request: request, value: 0, index: 0, data: Array(text.utf8) + [0])
    }

    /// Sends a command and reads what `getenv` and friends answer.
    public static func run(_ text: String, on device: USBDevice) throws -> String {
        let request: UInt8 = ["go", "bootx", "reboot", "reset"].contains(text) ? 1 : 0
        try send(text, request: request, on: device)
        guard text.hasPrefix("getenv") else { return "" }
        let reply = try device.controlIn(type: 0xc0, request: 0, value: 0, index: 0, length: 255)
        return String(decoding: reply.prefix { $0 != 0 }, as: UTF8.self)
    }
}
