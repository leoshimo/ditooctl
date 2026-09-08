import Foundation
import IOBluetooth
import DivoomProtocol

var verbose = false
func trace(_ text: String) { if verbose { log(text) } }
func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

// Some synchronous IOBluetooth metadata calls can block outside our run loop.
// Keep the entire hardware operation bounded even in that case.
final class CommandDeadline {
    private let timer = DispatchSource.makeTimerSource(queue: .global())
    init() {
        timer.schedule(deadline: .now() + 90)
        timer.setEventHandler {
            log("Error: Device operation exceeded 90 seconds. Its outcome is unknown; no write was retried.")
            _exit(1)
        }
        timer.resume()
    }
    func cancel() { timer.cancel() }
    deinit { timer.cancel() }
}

@discardableResult
func pump(seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
    return done()
}

func check(_ code: IOReturn, _ action: String) throws {
    guard code == kIOReturnSuccess else {
        let message = String(cString: mach_error_string(code))
        throw DivoomError("\(action): \(message) (\(String(format: "0x%08x", UInt32(bitPattern: code)))).")
    }
}

func deviceAt(_ address: String) throws -> IOBluetoothDevice {
    let normalized = address.replacingOccurrences(of: "-", with: ":")
    let components = normalized.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count == 6, components.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }),
          let device = IOBluetoothDevice(addressString: normalized) else { throw DivoomError("Expected a Bluetooth MAC address, such as 11:75:58:6F:AC:40.") }
    return device
}

func requestReply(_ connection: Connection, packet: [UInt8], command: UInt8) throws -> Reply {
    let previous = connection.onReply
    var response: Reply?
    connection.onReply = { reply in
        previous?(reply)
        if response == nil, reply.command == command { response = reply }
    }
    defer { connection.onReply = previous }
    trace("TX: \(packet.hex)")
    try connection.send(packet, settle: 0.2)
    _ = pump(seconds: 3) { response != nil || connection.closed }
    guard let response else { throw DivoomError(String(format: "No matching 0x%02x reply; operation stopped.", command)) }
    return response
}

func selectClock(_ connection: Connection, color: RGB? = nil) throws {
    let view = try requestReply(connection, packet: Divoom.packet([0x46]), command: 0x46)
    // Validate the complete report before changing any field.
    _ = try Divoom.clock(viewData: view.data)
    var settings = view.data
    if let color { settings.replaceSubrange(12...14, with: [color.r, color.g, color.b]) }
    let ack = try requestReply(connection, packet: Divoom.clock(viewData: settings), command: 0x45)
    guard ack.data == [0] else { throw DivoomError("Clock selection was not confirmed by the device.") }
    let after = try requestReply(connection, packet: Divoom.packet([0x46]), command: 0x46)
    guard after.data.count >= 20, after.data[0] == 0,
          Array(after.data[11...19]) == Array(settings[11...19]) else {
        throw DivoomError("Clock readback did not match the requested settings; device state is uncertain.")
    }
    trace("Clock selected; live readback confirms clock settings.")
}

func candidate(_ device: IOBluetoothDevice) -> Bool {
    let name = (device.name ?? "").lowercased()
    return ["divoom", "ditoo", "tivoo", "timebox", "pixoo"].contains { name.contains($0) }
}

func describe(_ device: IOBluetoothDevice) {
    print("\(device.addressString ?? "?")  \(device.name ?? "(unnamed)")  paired=\(device.isPaired()) connected=\(device.isConnected())")
}

final class Discovery: NSObject, IOBluetoothDeviceInquiryDelegate {
    var complete = false
    var result: IOReturn = kIOReturnSuccess
    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        result = error; complete = true
    }

    @discardableResult
    func run(seconds: UInt8, all: Bool, printResults: Bool = true) throws -> [IOBluetoothDevice] {
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else { throw DivoomError("Bluetooth inquiry unavailable. Enable Bluetooth in System Settings.") }
        inquiry.inquiryLength = seconds
        inquiry.updateNewDeviceNames = true
        inquiry.searchType = IOBluetoothDeviceSearchTypes(kIOBluetoothDeviceSearchClassic.rawValue)
        trace("Scanning Bluetooth Classic for \(seconds)s (name resolution can take up to 15s more)…")
        try check(inquiry.start(), "Start Bluetooth inquiry")
        let finished = pump(seconds: Double(seconds) + 15) { self.complete }
        if !finished {
            _ = inquiry.stop()
            trace("Name resolution timed out; showing partial discovery and paired records.")
        } else { try check(result, "Bluetooth inquiry") }
        let nearby = (inquiry.foundDevices() as? [IOBluetoothDevice]) ?? []
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var unique: [String: IOBluetoothDevice] = [:]
        for device in paired + nearby { if let address = device.addressString { unique[address] = device } }
        let devices = unique.values.filter { all || candidate($0) }.sorted { ($0.addressString ?? "") < ($1.addressString ?? "") }
        if printResults { for device in devices { describe(device) } }
        return devices
    }
}

final class SDPQuery: NSObject {
    var result: IOReturn?
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { result = status }

    func run(_ device: IOBluetoothDevice) throws {
        let previous = device.getLastServicesUpdate()
        try check(device.performSDPQuery(self), "Start service discovery")
        let completed = pump(seconds: 15) { self.result != nil || device.getLastServicesUpdate() != previous }
        if completed, let result { try check(result, "Service discovery"); trace("Fresh SDP query completed.") }
        else if device.getLastServicesUpdate() != previous {
            trace("SDP service records refreshed; macOS did not deliver the completion callback.")
        } else if device.services != nil {
            trace("SDP callback timed out; using cached service records dated \(String(describing: device.getLastServicesUpdate())).")
        } else { throw DivoomError("No service records. Pair the Divoom in System Settings → Bluetooth, close its phone app, then retry.") }
    }
}

// Match SPP UUID specifically: audio services also expose RFCOMM channels.
func sppChannel(_ device: IOBluetoothDevice) throws -> BluetoothRFCOMMChannelID {
    guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID.uuid16(0x1101)) else {
        throw DivoomError("Device has no Serial Port Profile (UUID 0x1101). No channel was guessed; this device may need another transport.")
    }
    var channel: BluetoothRFCOMMChannelID = 0
    try check(record.getRFCOMMChannelID(&channel), "Read SPP channel")
    guard (1...30).contains(channel) else { throw DivoomError("Invalid SPP channel \(channel).") }
    return channel
}

func inspect(_ device: IOBluetoothDevice) throws {
    describe(device)
    try SDPQuery().run(device)
    for record in (device.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
        print("service: \(record.getServiceName() ?? "(unnamed)")")
    }
    let channel = try sppChannel(device)
    print("display transport candidate: Bluetooth Classic SPP (UUID 0x1101), RFCOMM channel \(channel)")
    print("Advertised name identifies a device family; verify the exact variant on its label or in the Divoom app.")
}

final class Connection: NSObject, IOBluetoothRFCOMMChannelDelegate {
    let device: IOBluetoothDevice
    let wasConnected: Bool
    var channel: IOBluetoothRFCOMMChannel?
    var openResult: IOReturn?
    var writeResult: IOReturn?
    var closed = false
    var received = 0
    var decoder = ReplyDecoder()
    var onReply: ((Reply) -> Void)?
    let started = Date()

    init(device: IOBluetoothDevice) { self.device = device; self.wasConnected = device.isConnected() }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) { openResult = status }
    func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn) { writeResult = status }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        closed = true
        trace("RFCOMM channel closed.")
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard let pointer, length > 0 else { return }
        received += length
        let bytes = Array(Data(bytes: pointer, count: length))
        trace(String(format: "[%.2fs] RX %d bytes: %@", Date().timeIntervalSince(started), length, bytes.hex))
        for reply in decoder.append(bytes) {
            let description: String
            switch reply.command {
            case 0x09: description = "volume report"
            case 0x0b: description = "playback report"
            case 0x13: description = "working-mode report"
            case 0x76: description = "device-name suffix report"
            case 0xa8: description = "ambient sound control report"
            case 0xb6: description = "custom-item count report (research)"
            case 0x8e: description = "custom-slot information (research)"
            case 0x46: description = "view/settings report"
            case 0xbd: description = "extended report (meaning unverified)"
            default: description = "reply"
            }
            trace(String(format: "  command=0x%02x %@ data=%@", reply.command, description, reply.data.hex))
            onReply?(reply)
        }
    }

    func open() throws {
        // A discovery/inspect populates this record. Re-querying SDP on every
        // connection can contend with macOS's automatic audio-profile setup.
        if (try? sppChannel(device)) == nil {
            try SDPQuery().run(device)
        } else {
            trace("Using cached SPP service record (inspect refreshes it).")
        }
        let id = try sppChannel(device)
        trace("Opening \(device.name ?? "device") at \(device.addressString ?? "?") via SPP channel \(id)…")
        try check(device.openRFCOMMChannelAsync(&channel, withChannelID: id, delegate: self), "Start RFCOMM open")
        guard pump(seconds: 15, until: { self.openResult != nil || self.closed }), let result = openResult else {
            throw DivoomError("RFCOMM open timed out. Accept any pairing prompt; close the Divoom phone app and retry.")
        }
        try check(result, "RFCOMM open")
        guard !closed, channel?.isOpen() == true else { throw DivoomError("RFCOMM channel closed while opening.") }
        trace("RFCOMM open confirmed; MTU=\(channel!.getMTU()).")
    }

    func send(_ bytes: [UInt8], settle: Double = 1.5) throws {
        guard let channel, channel.isOpen(), !closed else { throw DivoomError("RFCOMM is not open.") }
        let chunkSize = min(512, Int(channel.getMTU()))
        guard chunkSize > 0 else { throw DivoomError("RFCOMM reported an invalid MTU.") }
        var written = 0
        for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
            let chunk = Array(bytes[offset..<min(bytes.count, offset + chunkSize)])
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk.count, alignment: 1)
            chunk.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: chunk.count) }
            writeResult = nil
            let started = channel.writeAsync(buffer, length: UInt16(chunk.count), refcon: nil)
            if started != kIOReturnSuccess {
                buffer.deallocate()
                closed = true
                try check(started, "Start RFCOMM write")
            }
            guard pump(seconds: 10, until: { self.writeResult != nil || self.closed }), let result = writeResult else {
                // Keep this outstanding buffer alive until process exit: a late framework
                // write callback may still reference it. Commands exit immediately on failure.
                closed = true
                throw DivoomError("RFCOMM write timed out or channel closed after \(written)/\(bytes.count) bytes. Display state is unknown.")
            }
            buffer.deallocate()
            if result != kIOReturnSuccess { closed = true }
            try check(result, "RFCOMM write after \(written)/\(bytes.count) bytes")
            written += chunk.count
            pump(seconds: 0.04)
        }
        trace("Transport write complete: \(written)/\(bytes.count) bytes. Waiting for device responses…")
        pump(seconds: settle)
        trace("Received \(received) bytes; raw replies are logged above. Physical display confirmation requires observation.")
        if closed { trace("Device closed the channel after the write.") }
    }

    func close() {
        _ = channel?.close()
        pump(seconds: 0.1)
        // Only release the baseband link if this command established it.
        if !wasConnected { _ = device.closeConnection() }
        channel = nil
    }
}
