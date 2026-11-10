import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum SocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case closed

    public var description: String {
        switch self {
        case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
        case .closed: "connection closed"
        }
    }
}

/// A blocking Unix stream socket.
public final class UnixSocket: @unchecked Sendable {
    let descriptor: Int32
    private let closeLock = NSLock()
    private var didClose = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    public static func connect(path: String) throws -> UnixSocket {
        let descriptor = try makeSocket()
        var address = makeAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            systemClose(descriptor)
            throw SocketError.system("connect", code)
        }
        return UnixSocket(descriptor: descriptor)
    }

    public static func listen(path: String) throws -> UnixSocket {
        unlink(path)
        let descriptor = try makeSocket()
        var address = makeAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, systemListen(descriptor, 16) == 0 else {
            let code = errno
            systemClose(descriptor)
            throw SocketError.system("listen", code)
        }
        return UnixSocket(descriptor: descriptor)
    }

    public func accept() throws -> UnixSocket {
        let client = systemAccept(descriptor, nil, nil)
        guard client >= 0 else { throw SocketError.system("accept", errno) }
        try Self.suppressBrokenPipeSignal(client)
        return UnixSocket(descriptor: client)
    }

    public func read(exactly count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress! + offset, count - offset, 0)
            }
            if received == 0 { throw SocketError.closed }
            if received < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("recv", errno)
            }
            offset += received
        }
        return bytes
    }

    /// Whatever is available, at most `limit` bytes, and empty at end of stream.
    public func read(upTo limit: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: limit)
        while true {
            let received = bytes.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, limit, 0) }
            if received < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("recv", errno)
            }
            bytes.removeLast(limit - received)
            return bytes
        }
    }

    /// Whatever arrives within `timeout`, at most `limit` bytes: empty when
    /// nothing did, and `SocketError.closed` at end of stream.
    public func read(upTo limit: Int, timeout: TimeInterval) throws -> [UInt8] {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&entry, 1, Int32(max(0, timeout) * 1000))
        if ready < 0 {
            if errno == EINTR { return [] }
            throw SocketError.system("poll", errno)
        }
        guard ready > 0 else { return [] }
        let bytes = try read(upTo: limit)
        if bytes.isEmpty { throw SocketError.closed }
        return bytes
    }

    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes {
                send(descriptor, $0.baseAddress! + offset, bytes.count - offset, sendFlags)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("send", errno)
            }
            offset += sent
        }
    }

    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !didClose else { return }
        didClose = true
        shutdown(descriptor, Int32(SHUT_RDWR))
        systemClose(descriptor)
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, streamType, 0)
        guard descriptor >= 0 else { throw SocketError.system("socket", errno) }
        try suppressBrokenPipeSignal(descriptor)
        return descriptor
    }

    private static func suppressBrokenPipeSignal(_ descriptor: Int32) throws {
        #if canImport(Darwin)
        // Darwin has no MSG_NOSIGNAL; apply this to accepted sockets too.
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                         socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            let code = errno
            systemClose(descriptor)
            throw SocketError.system("setsockopt(SO_NOSIGPIPE)", code)
        }
        #endif
    }

    private static func makeAddress(path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(capacity - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}

#if canImport(Glibc)
private let streamType = Int32(SOCK_STREAM.rawValue)
private let sendFlags = Int32(MSG_NOSIGNAL)
#else
private let streamType = SOCK_STREAM
private let sendFlags: Int32 = 0
#endif
private func systemConnect(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(socket, address, length)
}

private func systemListen(_ socket: Int32, _ backlog: Int32) -> Int32 {
    listen(socket, backlog)
}

private func systemAccept(
    _ socket: Int32,
    _ address: UnsafeMutablePointer<sockaddr>?,
    _ length: UnsafeMutablePointer<socklen_t>?
) -> Int32 {
    accept(socket, address, length)
}

private func systemClose(_ socket: Int32) {
    _ = close(socket)
}
