import Foundation
#if os(macOS)
import Darwin
#endif

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

    public static func all() -> [HostCheck] {
        #if os(macOS)
        [architecture(), hypervisor(), disk()]
        #else
        [architecture(), kvm(), pointerAuthentication(), vulkan(), disk()]
        #endif
    }

    static func architecture() -> HostCheck {
        var system = utsname()
        uname(&system)
        let name = field(of: system.sysname)
        let machine = field(of: system.machine)
        let release = field(of: system.release)
        #if os(macOS)
        let ok = name == "Darwin" && machine == "arm64"
        #else
        let ok = name == "Linux" && machine == "aarch64"
        #endif
        return HostCheck(name: "host", state: ok ? .ok : .missing, detail: "\(name) \(machine) \(release)")
    }

    #if os(macOS)
    static func hypervisor() -> HostCheck {
        var supported: Int32 = 0
        var size = MemoryLayout.size(ofValue: supported)
        guard sysctlbyname("kern.hv_support", &supported, &size, nil, 0) == 0 else {
            return HostCheck(name: "hvf", state: .missing, detail: "cannot query kern.hv_support: \(String(cString: strerror(errno)))")
        }
        return HostCheck(name: "hvf", state: supported == 1 ? .ok : .missing,
                         detail: supported == 1 ? "hardware virtualization available; QEMU also needs the hypervisor entitlement" : "hardware virtualization unavailable")
    }
    #endif

    /// Inspects QEMU's help output without creating a VM or touching its disks.
    public static func qemu(executable: String, accelerator: QEMUAccelerator = .host,
                            usbDeviceMode: Bool = false) -> HostCheck {
        do {
            let machines = try qemuOutput(executable, arguments: ["-machine", "help"])
            guard machines.status == 0, machines.text.split(separator: "\n").contains(where: {
                $0.split(whereSeparator: \.isWhitespace).first == "vmapple"
            }) else {
                return HostCheck(name: "qemu", state: .missing, detail: "\(executable) has no vmapple machine; use the matching patched QEMU build")
            }
            let accelerators = try qemuOutput(executable, arguments: ["-accel", "help"])
            guard accelerators.status == 0, accelerators.text.split(whereSeparator: \.isWhitespace).contains(Substring(accelerator.rawValue)) else {
                return HostCheck(name: "qemu", state: .missing, detail: "\(executable) has no \(accelerator.rawValue) accelerator")
            }
            let device = accelerator == .hvf ? "apple-gfx-mmio" : "reims-vgpu-mmio"
            let graphics = try qemuOutput(executable, arguments: ["-device", "\(device),help"])
            guard graphics.status == 0, graphics.text.contains(device) else {
                return HostCheck(name: "qemu", state: .missing, detail: "\(executable) has no \(device) device")
            }
            if usbDeviceMode {
                let usb = try qemuOutput(executable, arguments: ["-device", "vresearch-vusb-pci,help"])
                guard usb.status == 0, usb.text.contains("vresearch-vusb-pci") else {
                    return HostCheck(name: "qemu", state: .missing, detail: "\(executable) has no restore USB transport")
                }
            }
            return HostCheck(name: "qemu", state: .ok, detail: "\(executable): vmapple, \(accelerator.rawValue), \(device); help inspection only")
        } catch {
            return HostCheck(name: "qemu", state: .missing, detail: "cannot inspect \(executable): \(error)")
        }
    }

    private static func qemuOutput(_ executable: String, arguments: [String]) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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

    static func vulkan() -> HostCheck {
        let path = "/usr/share/vulkan/icd.d/nvidia_icd.json"
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
