import Foundation
import DivoomProtocol

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

func normalizedAddress(_ value: String) throws -> String {
    let parts = value.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else {
        throw UsageError("Expected a Bluetooth address such as AA:BB:CC:DD:EE:FF.")
    }
    return parts.joined(separator: ":").uppercased()
}

func validDeviceName(_ name: String) -> Bool {
    name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
}

struct DeviceConfig: Codable {
    var defaultDevice: String?
    var devices: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case defaultDevice = "default_device", devices }
}

struct DeviceStore {
    let url: URL
    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            guard xdg.hasPrefix("/") else { throw UsageError("XDG_DATA_HOME must be an absolute path.") }
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        }
        url = base.appendingPathComponent("ditooctl/devices.json")
    }

    func read() throws -> DeviceConfig {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return DeviceConfig()
        }
        let config: DeviceConfig
        do { config = try JSONDecoder().decode(DeviceConfig.self, from: data) }
        catch { throw DivoomError("Invalid device file at \(url.path): \(error.localizedDescription). It has not been overwritten.") }
        for (name, address) in config.devices {
            guard validDeviceName(name), (try? normalizedAddress(address)) == address else {
                throw DivoomError("Invalid name or address in \(url.path). Fix the file before continuing.")
            }
        }
        if let name = config.defaultDevice, config.devices[name] == nil {
            throw DivoomError("Default device '\(name)' is missing from \(url.path).")
        }
        return config
    }

    func write(_ config: DeviceConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    func resolve(_ selector: String?) throws -> (name: String?, address: String) {
        // An explicit address is usable even if local alias configuration is broken.
        if let selector, let address = try? normalizedAddress(selector) { return (nil, address) }
        let config = try read()
        guard let name = selector ?? config.defaultDevice else {
            throw UsageError("No default device. Run 'ditooctl device add NAME ADDRESS' or use --device ADDRESS.")
        }
        guard let address = config.devices[name] else { throw UsageError("Unknown device '\(name)'. Run 'ditooctl device list'.") }
        return (name, address)
    }
}
