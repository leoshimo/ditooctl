import Foundation
import CoreBluetooth
import IOBluetooth
import DivoomProtocol
import Darwin

final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    static func require() throws {
        if CBManager.authorization == .notDetermined {
            log("Waiting for Bluetooth permission on this Mac. Allow access for the terminal or application hosting ditooctl.")
            let delegate = BluetoothAccess()
            let manager = CBCentralManager(delegate: delegate, queue: nil,
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            _ = pump(seconds: 20) {
                CBManager.authorization != .notDetermined || manager.state == .unauthorized
            }
            withExtendedLifetime((delegate, manager)) {}
        }
        switch CBManager.authorization {
        case .allowedAlways: return
        case .denied:
            throw DivoomError("Bluetooth access is denied. Enable it for the terminal or host application in System Settings → Privacy & Security → Bluetooth on this Mac.")
        case .restricted:
            throw DivoomError("Bluetooth access is restricted on this Mac.")
        default:
            throw DivoomError("Bluetooth permission is pending or unavailable in this session. Run ditooctl from a terminal on this Mac and accept its Bluetooth permission prompt. An SSH session may not be able to request permission.")
        }
    }
}

final class Pairing: NSObject, IOBluetoothDevicePairDelegate {
    private var result: IOReturn?
    private var failure: String?
    private var pairingDeadline = Date.distantFuture

    func devicePairingStarted(_ sender: Any!) { trace("Pairing started.") }
    func devicePairingConnecting(_ sender: Any!) { trace("Connecting for pairing…") }
    func devicePairingConnected(_ sender: Any!) { trace("Pairing connection established.") }
    func devicePairingFinished(_ sender: Any!, error: IOReturn) { result = error }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        guard let pair = sender as? IOBluetoothDevicePair else { return }
        do {
            let answer = try readAnswer(String(format: "Does pairing code %06u match the code on the Ditoo? [y/N] ", numericValue))
            let accepted = ["y", "yes"].contains(answer.lowercased())
            if !accepted { failure = "Pairing confirmation was not accepted." }
            pair.replyUserConfirmation(accepted)
        } catch {
            failure = (error as? DivoomError)?.message ?? "Pairing confirmation could not be read."
            pair.replyUserConfirmation(false)
        }
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let pair = sender as? IOBluetoothDevicePair else { return }
        do {
            let answer = try readAnswer("Enter the pairing PIN supplied by the device or its manual: ")
            let bytes = Array(answer.utf8)
            guard (1...16).contains(bytes.count), answer.unicodeScalars.allSatisfy({ $0.isASCII }) else {
                throw DivoomError("Pairing PIN must contain 1–16 ASCII characters.")
            }
            var pin = BluetoothPINCode()
            withUnsafeMutableBytes(of: &pin) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                buffer.copyBytes(from: bytes)
            }
            pair.replyPINCode(bytes.count, pinCode: &pin)
        } catch {
            failure = (error as? DivoomError)?.message ?? "Pairing PIN could not be read."
        }
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        log(String(format: "Enter pairing code %06u on the Ditoo if it asks for one.", passkey))
    }

    // Keep Bluetooth callbacks and the deadline alive while waiting for a person.
    // Noninteractive calls never accept a comparison or guess a PIN.
    private func readAnswer(_ prompt: String) throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            throw DivoomError("Pairing needs interactive confirmation. Run 'ditooctl device pair' in a terminal on this Mac, or pair in System Settings → Bluetooth.")
        }
        FileHandle.standardError.write(Data(prompt.utf8))
        let end = min(Date().addingTimeInterval(30), pairingDeadline)
        var bytes: [UInt8] = []
        while Date() < end && result == nil {
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&input, 1, 0)
            if ready < 0 && errno != EINTR { break }
            if ready > 0 {
                var byte: UInt8 = 0
                guard read(STDIN_FILENO, &byte, 1) == 1 else { break }
                if byte == 10 || byte == 13 {
                    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                }
                guard bytes.count < 128 else { throw DivoomError("Pairing response is too long.") }
                bytes.append(byte)
            } else { _ = pump(seconds: 0.05) }
        }
        throw DivoomError("Pairing response timed out or input was closed.")
    }

    func run(_ device: IOBluetoothDevice, address: String) throws -> Bool {
        if device.isPaired() { return true }
        guard let pair = IOBluetoothDevicePair(device: device) else {
            throw DivoomError("macOS could not create a pairing request for \(address).")
        }
        pair.delegate = self
        var finished = false
        defer {
            pair.delegate = nil
            if !finished { pair.stop() }
        }
        log("Pairing \(address) on this Mac. Keep the Ditoo on and disconnect it from another host if needed.")
        pairingDeadline = Date().addingTimeInterval(60)
        try check(pair.start(), "Start Bluetooth pairing")
        _ = pump(seconds: max(0, pairingDeadline.timeIntervalSinceNow)) { self.result != nil || self.failure != nil }
        if let failure { throw DivoomError(failure) }
        guard let result else {
            throw DivoomError("Pairing timed out. Make the Ditoo discoverable and disconnect its active connection to another host, then retry.")
        }
        if result != kIOReturnSuccess {
            // This callback can return Bluetooth HCI statuses, which are not
            // Mach errors (for example, 0x04 means page timeout).
            let descriptions: [IOReturn: String] = [
                0x04: "the Ditoo did not answer the connection attempt (page timeout)",
                0x05: "authentication failed",
                0x06: "PIN or link key missing",
                0x08: "connection timed out",
                0x17: "the device rejected repeated pairing attempts",
                0x18: "the device is not allowing pairing",
                0x22: "the device did not respond in time",
                0x38: "the device is busy pairing"
            ]
            if (1...255).contains(result) {
                let detail = descriptions[result] ?? "Bluetooth controller error"
                throw DivoomError(String(format: "Bluetooth pairing failed: %@ (HCI 0x%02x). Keep the Ditoo nearby and discoverable; disconnect another host if needed.", detail, result))
            }
            try check(result, "Bluetooth pairing")
        }
        _ = pump(seconds: 3) { device.isPaired() }
        guard device.isPaired() else { throw DivoomError("Pairing finished, but macOS does not report the device as paired.") }
        finished = true
        return false
    }
}
