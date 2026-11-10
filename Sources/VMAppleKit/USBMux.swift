import Foundation

/// Apple's USB mux on the RestoreOS device: version 2 framing, and a small TCP
/// over it. The device's buffers are 32 KiB and it drops a transfer that does
/// not hold one whole packet.
final class USBMuxLink: @unchecked Sendable {
    static let maximumPacket = 0x8000

    private enum Proto {
        static let version: UInt32 = 0
        static let setup: UInt32 = 2
        static let tcp: UInt32 = 6
    }

    enum TCPFlag {
        static let syn: UInt8 = 2
        static let reset: UInt8 = 4
        static let ack: UInt8 = 16
        static let fin: UInt8 = 1
    }

    private static let magic: UInt32 = 0xfeed_face
    private static let headerSize = 16
    private static let tcpHeaderSize = 20
    static let payloadLimit = maximumPacket - headerSize - tcpHeaderSize

    private let device: USBDevice
    private let endpoints: USBMuxEndpoints
    private let log: @Sendable (String) -> Void
    private let sendLock = NSLock()
    private let state = NSCondition()
    private var version: UInt32 = 0
    private var transmitSequence: UInt16 = 0
    private var receiveSequence: UInt16 = 0xffff
    private var connections: [UInt16: USBMuxConnection] = [:]
    private var nextPort: UInt16 = 1
    private var buffer: [UInt8] = []
    private(set) var ended = false

    init(device: USBDevice, endpoints: USBMuxEndpoints, log: @escaping @Sendable (String) -> Void) {
        self.device = device
        self.endpoints = endpoints
        self.log = log
    }

    func note(_ message: String) { log(message) }

    func start() throws {
        let thread = Thread { [self] in inputLoop() }
        thread.name = "usbmux"
        thread.start()
        var body = [UInt8]()
        body.appendBigEndian(UInt32(2))
        body.appendBigEndian(UInt32(0))
        body.appendBigEndian(UInt32(0))
        try sendPacket(proto: Proto.version, body: body)
        let deadline = Date(timeIntervalSinceNow: 10)
        state.lock()
        defer { state.unlock() }
        while version == 0 {
            if ended { throw USBError.unplugged }
            if !state.wait(until: deadline) { throw USBError.timeout("the mux version") }
        }
    }

    func waitUntilEnded() {
        state.lock()
        defer { state.unlock() }
        while !ended { state.wait() }
    }

    func connect(port: UInt16, client: UnixSocket) throws -> USBMuxConnection? {
        state.lock()
        let local = nextPort
        nextPort &+= 1
        let connection = USBMuxConnection(mux: self, local: local, remote: port, client: client)
        connections[local] = connection
        state.unlock()
        try connection.send(flags: TCPFlag.syn)
        guard connection.waitUntilEstablished(timeout: 10) else {
            remove(connection)
            return nil
        }
        return connection
    }

    func remove(_ connection: USBMuxConnection) {
        state.lock()
        connections[connection.local] = nil
        state.unlock()
    }

    // MARK: - Packets

    func sendTCP(
        local: UInt16,
        remote: UInt16,
        sequence: UInt32,
        acknowledgement: UInt32,
        flags: UInt8,
        window: UInt32,
        data: ArraySlice<UInt8> = []
    ) throws {
        var header = [UInt8]()
        header.appendBigEndian(local)
        header.appendBigEndian(remote)
        header.appendBigEndian(sequence)
        header.appendBigEndian(acknowledgement)
        header.append(5 << 4)
        header.append(flags)
        header.appendBigEndian(UInt16(window >> 8))
        header.appendBigEndian(UInt16(0))
        header.appendBigEndian(UInt16(0))
        try sendPacket(proto: Proto.tcp, body: header + data)
    }

    private func sendPacket(proto: UInt32, body: [UInt8]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        let useLongHeader = version >= 2
        let total = (useLongHeader ? Self.headerSize : 8) + body.count
        var packet = [UInt8]()
        packet.reserveCapacity(total)
        packet.appendBigEndian(proto)
        packet.appendBigEndian(UInt32(total))
        if useLongHeader {
            if proto == Proto.setup {
                transmitSequence = 0
                receiveSequence = 0xffff
            }
            packet.appendBigEndian(Self.magic)
            packet.appendBigEndian(transmitSequence)
            packet.appendBigEndian(receiveSequence)
            transmitSequence &+= 1
        }
        packet += body
        try device.link.bulkOut(endpoint: endpoints.output, data: packet)
        if packet.count % endpoints.maximumPacketSize == 0 {
            try device.link.bulkOut(endpoint: endpoints.output, data: [])
        }
    }

    private func inputLoop() {
        do {
            while true {
                buffer += try device.link.bulkIn(endpoint: endpoints.input & 0x7f, timeout: .infinity)
                while buffer.count >= 8 {
                    let length = Int(buffer.bigEndianUInt32(at: 4))
                    guard (8...0x10_0000).contains(length) else {
                        buffer.removeAll()
                        break
                    }
                    guard buffer.count >= length else { break }
                    let packet = Array(buffer[..<length])
                    buffer.removeFirst(length)
                    try dispatch(packet)
                }
            }
        } catch {
            log("USB mux input ended: \(error)")
            state.lock()
            ended = true
            let remaining = Array(connections.values)
            connections.removeAll()
            state.broadcast()
            state.unlock()
            remaining.forEach { $0.deviceEnded() }
        }
    }

    private func dispatch(_ packet: [UInt8]) throws {
        let proto = packet.bigEndianUInt32(at: 0)
        let headerSize = version >= 2 ? Self.headerSize : 8
        if version >= 2, packet.count >= 16 {
            sendLock.lock()
            receiveSequence = packet.bigEndianUInt16(at: 12)
            sendLock.unlock()
        }
        switch proto {
        case Proto.version:
            let major = packet.bigEndianUInt32(at: headerSize)
            sendLock.lock()
            version = major
            sendLock.unlock()
            if major >= 2 { try sendPacket(proto: Proto.setup, body: [0x07]) }
            state.lock()
            state.broadcast()
            state.unlock()
        case Proto.tcp:
            guard packet.count >= headerSize + Self.tcpHeaderSize else { return }
            let tcp = headerSize
            let local = packet.bigEndianUInt16(at: tcp + 2)
            state.lock()
            let connection = connections[local]
            state.unlock()
            try connection?.receive(
                acknowledgement: packet.bigEndianUInt32(at: tcp + 8),
                flags: packet[tcp + 13],
                window: UInt32(packet.bigEndianUInt16(at: tcp + 14)) << 8,
                data: Array(packet[(tcp + Self.tcpHeaderSize)...])
            )
        default:
            break
        }
    }
}

struct USBMuxEndpoints: Sendable {
    let configuration: UInt8
    let input: UInt8
    let output: UInt8
    let maximumPacketSize: Int

    /// Finds the mux interface, class ff/fe/02, in a configuration descriptor.
    static func parse(configuration descriptor: [UInt8]) -> USBMuxEndpoints? {
        var offset = 0
        var inMux = false
        var input: UInt8?
        var output: UInt8?
        var packetSize = 512
        while offset + 2 <= descriptor.count, descriptor[offset] > 0 {
            let length = Int(descriptor[offset])
            guard offset + length <= descriptor.count else { break }
            switch descriptor[offset + 1] {
            case 4 where length >= 9:
                inMux = descriptor[offset + 5] == 0xff && descriptor[offset + 6] == 0xfe &&
                    descriptor[offset + 7] == 0x02
            case 5 where inMux && length >= 7:
                let address = descriptor[offset + 2]
                packetSize = Int(descriptor[offset + 4]) | Int(descriptor[offset + 5]) << 8
                if address & 0x80 != 0 { input = address } else { output = address }
            default:
                break
            }
            offset += length
        }
        guard let input, let output else { return nil }
        return USBMuxEndpoints(
            configuration: descriptor[5],
            input: input,
            output: output,
            maximumPacketSize: packetSize
        )
    }
}

/// One TCP connection through the mux, joined to one usbmuxd client.
final class USBMuxConnection: @unchecked Sendable {
    let local: UInt16
    let remote: UInt16

    private let mux: USBMuxLink
    private let client: UnixSocket
    private let state = NSCondition()
    private let sendLock = NSLock()
    private var transmitSequence: UInt32 = 0
    private var transmitAcknowledgement: UInt32 = 0
    private var receivedAcknowledgement: UInt32 = 0
    private var receiveWindow: UInt32 = 0
    private var established = false
    private var refused = false
    private var ended = false
    private var outbox: [[UInt8]] = []
    private var transmittedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private static let transmitWindow: UInt32 = 131_072

    init(mux: USBMuxLink, local: UInt16, remote: UInt16, client: UnixSocket) {
        self.mux = mux
        self.local = local
        self.remote = remote
        self.client = client
    }

    func send(flags: UInt8, data: ArraySlice<UInt8> = []) throws {
        // Data and ACKs originate on different threads. Reserve sequence
        // space before USB I/O, and keep packet order equal to sequence order.
        sendLock.lock()
        defer { sendLock.unlock() }
        state.lock()
        let sequence = transmitSequence
        let acknowledgement = transmitAcknowledgement
        transmitSequence &+= UInt32(data.count)
        transmittedBytes &+= UInt64(data.count)
        state.unlock()
        try mux.sendTCP(
            local: local,
            remote: remote,
            sequence: sequence,
            acknowledgement: acknowledgement,
            flags: flags,
            window: Self.transmitWindow,
            data: data
        )
    }

    func waitUntilEstablished(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        state.lock()
        defer { state.unlock() }
        while !established, !refused, !ended {
            if !state.wait(until: deadline) { return false }
        }
        return established
    }

    func receive(acknowledgement: UInt32, flags: UInt8, window: UInt32, data: [UInt8]) throws {
        typealias Flag = USBMuxLink.TCPFlag
        state.lock()
        receivedAcknowledgement = acknowledgement
        receiveWindow = window
        let wasEstablished = established
        if !wasEstablished {
            if flags == Flag.syn | Flag.ack {
                transmitSequence &+= 1
                transmitAcknowledgement &+= 1
                established = true
            } else {
                refused = true
            }
        } else if flags & (Flag.reset | Flag.fin) != 0 {
            ended = true
        } else if !data.isEmpty {
            transmitAcknowledgement &+= UInt32(data.count)
            receivedBytes &+= UInt64(data.count)
            outbox.append(data)
        }
        let finished = ended
        // Apple's mux expects an ACK even for a window-only update, as in
        // usbmuxd's device_tcp_input; it is not a general TCP stack.
        let shouldAcknowledge = !refused && !finished
        state.broadcast()
        state.unlock()
        if finished {
            let reason = String(decoding: data.prefix(512), as: UTF8.self)
            mux.note("USB mux \(local):\(remote) guest closed: flags=\(flags) ack=\(acknowledgement) window=\(window) reason=\(reason)")
            mux.remove(self)
        }
        if shouldAcknowledge { try send(flags: Flag.ack) }
    }

    func deviceEnded() {
        state.lock()
        ended = true
        state.broadcast()
        state.unlock()
    }

    /// Runs the connection until either side leaves.
    func pump() {
        let writer = Thread { [self] in deliverToClient() }
        writer.name = "usbmux-client"
        writer.start()
        defer {
            state.lock()
            let alreadyEnded = ended
            let summary = "USB mux \(local):\(remote) ended: tx=\(transmittedBytes) rx=\(receivedBytes) seq=\(transmitSequence) ack=\(receivedAcknowledgement) window=\(receiveWindow)"
            ended = true
            state.broadcast()
            state.unlock()
            mux.note(summary)
            if !alreadyEnded {
                try? send(flags: USBMuxLink.TCPFlag.reset)
                mux.remove(self)
            }
            client.close()
        }
        do {
            while true {
                let bytes = try client.read(upTo: USBMuxLink.payloadLimit)
                if bytes.isEmpty { return }
                var offset = 0
                while offset < bytes.count {
                    let room = try waitForWindow()
                    let end = min(offset + room, bytes.count)
                    try send(flags: USBMuxLink.TCPFlag.ack, data: bytes[offset..<end])
                    offset = end
                }
            }
        } catch {
            mux.note("USB mux \(local):\(remote) send ended: \(error)")
        }
    }

    private func waitForWindow() throws -> Int {
        state.lock()
        defer { state.unlock() }
        while true {
            if ended { throw SocketError.closed }
            let inFlight = transmitSequence &- receivedAcknowledgement
            if inFlight < receiveWindow { return Int(receiveWindow - inFlight) }
            if !state.wait(until: Date(timeIntervalSinceNow: 5)) {
                let summary = "USB mux \(local):\(remote) waiting: seq=\(transmitSequence) ack=\(receivedAcknowledgement) window=\(receiveWindow) inFlight=\(inFlight)"
                state.unlock()
                mux.note(summary)
                state.lock()
            }
        }
    }

    private func deliverToClient() {
        while true {
            state.lock()
            while outbox.isEmpty, !ended { state.wait() }
            if outbox.isEmpty {
                state.unlock()
                client.close()
                return
            }
            let bytes = outbox.removeFirst()
            state.unlock()
            do {
                try client.write(bytes)
            } catch {
                mux.note("USB mux \(local):\(remote) client write ended: \(error)")
                return
            }
        }
    }
}
