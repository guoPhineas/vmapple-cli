import Foundation

/// usbmuxd for one device, with no root and no libusb: the plist protocol on a
/// Unix socket, for libusbmuxd's `USBMUXD_SOCKET_ADDRESS`.
public final class USBMuxServer: @unchecked Sendable {
    private let listener: UnixSocket
    private let log: @Sendable (String) -> Void
    private let state = NSLock()
    private var mux: USBMuxLink?
    private var properties: [String: Any] = [:]
    private var listeners: [UnixSocket] = []
    private var closed = false
    private let deviceID = 1

    public init(socketPath: String, log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.log = log
        listener = try UnixSocket.listen(path: socketPath)
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "usbmuxd"
        thread.start()
    }

    public var isClosed: Bool {
        state.lock()
        defer { state.unlock() }
        return closed
    }

    public func close() {
        state.lock()
        closed = true
        state.unlock()
        listener.close()
    }

    public func waitForDevice(timeout: TimeInterval) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            state.lock()
            let attached = mux != nil
            state.unlock()
            if attached { return }
            usleep(100_000)
        }
        throw USBError.timeout("the restore OS")
    }

    /// Serves the device until the guest takes it away.
    public func serve(device: USBDevice) throws {
        let (endpoints, serial) = try prepare(device: device)
        let link = USBMuxLink(device: device, endpoints: endpoints, log: log)
        try link.start()
        state.lock()
        mux = link
        properties = [
            "ConnectionSpeed": 480_000_000,
            "ConnectionType": "USB",
            "DeviceID": deviceID,
            "LocationID": 0,
            "ProductID": Int(device.descriptor.product),
            "SerialNumber": serial,
            "UDID": serial,
            "USBSerialNumber": serial,
        ]
        let current = listeners
        state.unlock()
        for client in current {
            try? send(attachedMessage(), to: client, tag: 0)
        }
        link.waitUntilEnded()
        state.lock()
        mux = nil
        let remaining = listeners
        state.unlock()
        for client in remaining {
            try? send(["MessageType": "Detached", "DeviceID": deviceID], to: client, tag: 0)
        }
    }

    private func prepare(device: USBDevice) throws -> (USBMuxEndpoints, String) {
        let configuration = device.descriptor.configurations
        let index = UInt16(configuration - 1)
        let head = try device.controlIn(type: 0x80, request: 6, value: 0x0200 | index, index: 0, length: 9)
        guard head.count >= 9 else { throw USBError.malformed("short configuration descriptor") }
        let total = UInt16(head[2]) | UInt16(head[3]) << 8
        let descriptor = try device.controlIn(type: 0x80, request: 6, value: 0x0200 | index, index: 0, length: total)
        guard let endpoints = USBMuxEndpoints.parse(configuration: descriptor) else {
            throw USBError.malformed("no mux interface in configuration \(configuration)")
        }
        let serial = try device.string(at: device.descriptor.serialIndex)
            .split(separator: "\0", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        try device.setConfiguration(endpoints.configuration)
        return (endpoints, serial)
    }

    private func attachedMessage() -> [String: Any] {
        state.lock()
        defer { state.unlock() }
        return ["MessageType": "Attached", "DeviceID": deviceID, "Properties": properties]
    }

    // MARK: - Clients

    private func acceptLoop() {
        while let client = try? listener.accept() {
            let thread = Thread { [self] in serve(client: client) }
            thread.name = "usbmuxd-client"
            thread.start()
        }
    }

    private func serve(client: UnixSocket) {
        defer { forget(client) }
        do {
            while true {
                let header = try client.read(exactly: 16)
                let length = Int(header.littleEndianUInt32(at: 0))
                let tag = header.littleEndianUInt32(at: 12)
                guard length >= 16 else { return }
                let body = Data(try client.read(exactly: length - 16))
                let message = try PropertyListSerialization.propertyList(from: body, format: nil)
                guard let request = message as? [String: Any] else { return }
                if try handle(request, client: client, tag: tag) { return }
            }
        } catch {}
    }

    /// True when the socket has become a connection to the device.
    private func handle(_ request: [String: Any], client: UnixSocket, tag: UInt32) throws -> Bool {
        state.lock()
        let link = mux
        state.unlock()
        switch request["MessageType"] as? String {
        case "ListDevices":
            let devices: [[String: Any]] = link == nil ? [] : [attachedMessage()]
            try send(["DeviceList": devices], to: client, tag: tag)
        case "Listen":
            try send(result(0), to: client, tag: tag)
            state.lock()
            listeners.append(client)
            state.unlock()
            if link != nil { try send(attachedMessage(), to: client, tag: 0) }
        case "Connect":
            let swapped = (request["PortNumber"] as? Int) ?? 0
            let port = UInt16(truncatingIfNeeded: swapped).byteSwapped
            guard let link, let connection = try link.connect(port: port, client: client) else {
                try send(result(3), to: client, tag: tag)
                return false
            }
            try send(result(0), to: client, tag: tag)
            connection.pump()
            return true
        case "ReadBUID":
            try send(["BUID": "00000000-0000-0000-0000-000000000000"], to: client, tag: tag)
        default:
            try send(result(2), to: client, tag: tag)
        }
        return false
    }

    private func result(_ number: Int) -> [String: Any] {
        ["MessageType": "Result", "Number": number]
    }

    private func send(_ message: [String: Any], to client: UnixSocket, tag: UInt32) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var frame = [UInt8]()
        frame.appendLittleEndian(UInt32(body.count + 16))
        frame.appendLittleEndian(UInt32(1))
        frame.appendLittleEndian(UInt32(8))
        frame.appendLittleEndian(tag)
        frame += body
        try client.write(frame)
    }

    private func forget(_ client: UnixSocket) {
        state.lock()
        listeners.removeAll { $0 === client }
        state.unlock()
    }
}
