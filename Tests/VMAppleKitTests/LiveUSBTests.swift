//
//  LiveUSBTests.swift
//  vmapple-cli
//
//  Created by Phineas Guo on 2026/11/10.
//

import Foundation
import Testing

@testable import VMAppleKit

@Suite struct LiveUSBTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VMAPPLE_TEST_USB_SOCKET"] != nil))
    func enumeratesOpenAVBDFU() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VMAPPLE_TEST_USB_SOCKET"])
        let link = try VUSBLink(socketPath: path)
        defer { link.close() }
        let device = try link.waitForDevice([USBProduct.dfu], timeout: 20)
        #expect(device.descriptor.vendor == 0x05ac)
        #expect(device.descriptor.product == USBProduct.dfu)
        let identity = try device.string(at: device.descriptor.serialIndex)
        #expect(identity.contains("CPID:FE00"))
        #expect(identity.contains("BDID:20"))
        if let ecid = ProcessInfo.processInfo.environment["VMAPPLE_TEST_USB_ECID"] {
            #expect(identity.contains("ECID:\(ecid.uppercased())"))
        }
        print("DFU USB identity: \(identity)")
    }
}
