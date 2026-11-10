//
//  UnixSocketTests.swift
//  vmapple-cli
//
//  Created by Phineas Guo on 2026/11/10.
//

import Foundation
import Testing

@testable import VMAppleKit

@Suite struct UnixSocketTests {
    @Test(arguments: [true, false])
    func disconnectedPeerThrowsInsteadOfTerminatingTheProcess(writeFromAcceptedSocket: Bool) throws {
        let path = "/tmp/vmapple-socket-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let listener = try UnixSocket.listen(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        defer { client.close() }
        let server = try listener.accept()
        defer { server.close() }
        let writer = writeFromAcceptedSocket ? server : client
        let peer = writeFromAcceptedSocket ? client : server
        peer.close()
        #expect(try writer.read(upTo: 1).isEmpty)
        #expect(throws: SocketError.self) { try writer.write([1]) }
    }
}
