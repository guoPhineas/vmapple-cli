import Foundation

/// A virtual Mac on disk: its disks, its identity and its runtime files.
public struct VirtualMachine: Sendable {
    public struct Configuration: Codable, Sendable {
        public var ecid: UInt64
        public var diskBytes: UInt64
        /// Where the installed iBoot hands off to the kernel, for QEMU.
        public var handoffAddresses: [UInt64]?
        public var installed: String?
        /// The OCI image it was pulled from, by digest.
        public var image: String?
        /// Whether the guest is told its disk encrypts inline, as QEMU's
        /// virtio disk does by default. A disk restored by Virtualization.framework
        /// is told it does not, so its Data volume is unencrypted and mounts
        /// only when the guest is told the same here. Nil means true.
        public var inlineEncryption: Bool?
    }

    public static let auxBytes: UInt64 = 33_570_816

    public let directory: URL
    public let configuration: Configuration

    public var aux: URL { directory.appending(path: "aux.img") }
    public var disk: URL { directory.appending(path: "disk.img") }
    public var serialLog: URL { directory.appending(path: "serial.log") }
    public var serialSocket: URL { directory.appending(path: "serial.sock") }
    public var qemuLog: URL { directory.appending(path: "qemu.log") }
    public var qmpSocket: URL { directory.appending(path: "qmp.sock") }
    public var usbSocket: URL { directory.appending(path: "vusb.sock") }
    public var muxSocket: URL { directory.appending(path: "usbmuxd.sock") }
    public var guestMemory: URL { directory.appending(path: "guest.ram") }
    public var ticket: URL { directory.appending(path: "ticket.im4m") }

    private static func configurationURL(_ directory: URL) -> URL {
        directory.appending(path: "vm.json")
    }

    public static func create(at directory: URL, diskGiB: UInt64, inlineEncryption: Bool? = nil) throws -> VirtualMachine {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ecid: UInt64 = 0
        while ecid == 0 {
            ecid = UInt64.random(in: 1...(.max >> 1))
        }
        let configuration = Configuration(ecid: ecid, diskBytes: diskGiB << 30, handoffAddresses: nil, installed: nil, image: nil, inlineEncryption: inlineEncryption)
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: configurationURL(directory))
        let machine = VirtualMachine(directory: directory, configuration: configuration)
        try machine.resetDisks()
        return machine
    }

    public static func open(at directory: URL) throws -> VirtualMachine {
        let data = try Data(contentsOf: configurationURL(directory))
        return VirtualMachine(
            directory: directory,
            configuration: try JSONDecoder().decode(Configuration.self, from: data)
        )
    }

    public func save(_ configuration: Configuration) throws {
        try JSONEncoder().encode(configuration).write(to: Self.configurationURL(directory))
    }

    /// Blank disks, so that the ROM falls back to DFU.
    public func resetDisks() throws {
        for (url, size) in [(aux, Self.auxBytes), (disk, configuration.diskBytes)] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: size)
            try handle.close()
        }
    }
}
