import Foundation

// MARK: - Checks

public struct HostCheck: Sendable {
    public enum State: String, Sendable {
        case ok
        case missing
    }

    public let name: String
    public let state: State
    public let detail: String
}

public enum HostChecks {
    /// Room for an IPSW, a guest disk, and the QEMU and Rust build trees.
    static let minimumFreeBytes: Int64 = 100 * 1024 * 1024 * 1024

    public static func all(accelerator: QEMUAccelerator = .kvm, vulkanICD: String? = nil) -> [HostCheck] {
        let host = architecture(accelerator: accelerator)
        let graphics = vulkan(accelerator: accelerator, icd: vulkanICD)
        let storage = disk()
        if accelerator == .kvm {
            return [host, kvm(), pointerAuthentication(), graphics, storage]
        }
        return [host, graphics, storage]
    }

    static func architecture(accelerator: QEMUAccelerator = .kvm) -> HostCheck {
        var system = utsname()
        uname(&system)
        let name = field(of: system.sysname)
        let machine = field(of: system.machine)
        let release = field(of: system.release)
        let supported = accelerator == .kvm ? ["aarch64"] : ["aarch64", "x86_64"]
        let ok = name == "Linux" && supported.contains(machine)
        return HostCheck(name: "host", state: ok ? .ok : .missing, detail: "\(name) \(machine) \(release)")
    }

    static func kvm() -> HostCheck {
        let path = "/dev/kvm"
        guard FileManager.default.fileExists(atPath: path) else {
            return HostCheck(name: "kvm", state: .missing, detail: "\(path) does not exist")
        }
        let ok = access(path, R_OK | W_OK) == 0
        return HostCheck(
            name: "kvm",
            state: ok ? .ok : .missing,
            detail: ok ? path : "no access to \(path): add this user to the kvm group"
        )
    }

    static func pointerAuthentication() -> HostCheck {
        let features = HostCores.readCPUInfo()
            .split(separator: "\n")
            .first { $0.hasPrefix("Features") }?
            .split(separator: " ") ?? []
        let ok = features.contains("paca") && features.contains("pacg")
        return HostCheck(name: "pac", state: ok ? .ok : .missing, detail: ok ? "paca pacg" : "no paca/pacg")
    }

    static func vulkan(accelerator: QEMUAccelerator = .kvm, icd: String? = nil) -> HostCheck {
        guard accelerator == .kvm || icd != nil else {
            return HostCheck(name: "vulkan", state: .missing, detail: "pass --vulkan-icd with a software Vulkan driver")
        }
        let path = icd ?? "/usr/share/vulkan/icd.d/nvidia_icd.json"
        let ok = FileManager.default.fileExists(atPath: path)
        return HostCheck(name: "vulkan", state: ok ? .ok : .missing, detail: ok ? path : "no \(path)")
    }

    static func disk() -> HostCheck {
        let directory = FileManager.default.currentDirectoryPath
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory)
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let detail = ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
        return HostCheck(name: "disk", state: free >= minimumFreeBytes ? .ok : .missing, detail: detail)
    }

    private static func field<T>(of value: T) -> String {
        withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
