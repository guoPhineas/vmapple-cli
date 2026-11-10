//
//  USBMuxConnectionTests.swift
//  vmapple-cli
//
//  Created by Phineas Guo on 2026/11/10.
//

import Foundation
import Testing

@testable import VMAppleKit

@Suite struct USBMuxConnectionTests {
    @Test func acknowledgesWindowUpdatesInTransmitOrder() async throws {
        let path = "/tmp/vmapple-mux-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let listener = try UnixSocket.listen(path: path)
        defer { listener.close() }
        let usb = try VUSBLink(socketPath: path)
        defer { usb.close() }
        let peer = try listener.accept()
        defer { peer.close() }
        let descriptor = try USBDeviceDescriptor([UInt8](repeating: 0, count: 18))
        let mux = USBMuxLink(
            device: USBDevice(link: usb, descriptor: descriptor),
            endpoints: USBMuxEndpoints(configuration: 4, input: 0x81, output: 1, maximumPacketSize: 512),
            log: { _ in }
        )
        let connection = USBMuxConnection(mux: mux, local: 1, remote: 62078, client: peer)

        // Complete SYN/ACK, then reopen the receive window without sending
        // application bytes. Both must produce an ACK on the USB transport.
        for flags: UInt8 in [0x12, 0x10] {
            let receive = Task.detached {
                try connection.receive(acknowledgement: 1, flags: flags, window: 131_072, data: [])
            }
            let prefix = try peer.read(upTo: 6, timeout: 2)
            try #require(prefix.count == 6)
            #expect(prefix[4] == 1)
            #expect(prefix[5] == 1)
            let packet = try peer.read(exactly: Int(prefix.littleEndianUInt32(at: 0)))
            try #require(packet.count == 28)
            #expect(packet.bigEndianUInt32(at: 0) == 6)
            #expect(packet[21] == 0x10)
            #expect(packet.bigEndianUInt32(at: 12) == 1)
            #expect(packet.bigEndianUInt32(at: 16) == 1)
            try peer.write([2, 0, 0, 0, 1, 1])
            try await receive.value
        }

        // Delay USB completion while a device ACK arrives on another thread.
        // The next emitted ACK must follow the data's reserved sequence space.
        let sending = Task.detached {
            try connection.send(flags: 0x10, data: [1, 2, 3, 4][...])
        }
        let dataPrefix = try peer.read(upTo: 6, timeout: 2)
        try #require(dataPrefix.count == 6)
        let data = try peer.read(exactly: Int(dataPrefix.littleEndianUInt32(at: 0)))
        try #require(data.count == 32)
        #expect(data.bigEndianUInt32(at: 12) == 1)
        let acknowledging = Task.detached {
            try connection.receive(acknowledgement: 5, flags: 0x10, window: 131_072, data: [])
        }
        try peer.write([2, 0, 0, 0, 1, 1])
        try await sending.value
        let ackPrefix = try peer.read(upTo: 6, timeout: 2)
        try #require(ackPrefix.count == 6)
        let ack = try peer.read(exactly: Int(ackPrefix.littleEndianUInt32(at: 0)))
        try #require(ack.count == 28)
        #expect(ack.bigEndianUInt32(at: 12) == 5)
        try peer.write([2, 0, 0, 0, 1, 1])
        try await acknowledging.value
    }
}
