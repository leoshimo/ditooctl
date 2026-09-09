import Foundation
import IOBluetooth
import DivoomProtocol

struct Arguments {
    var words: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]
    init(_ raw: [String]) throws {
        var index = 0
        var literal = false
        while index < raw.count {
            let word = raw[index]
            if !literal && word == "--" { literal = true; index += 1; continue }
            if !literal && word.hasPrefix("-") {
                let name = word == "-h" ? "--help" : word
                if ["--device","--color"].contains(name) {
                    guard values[name] == nil, index + 1 < raw.count, !raw[index+1].hasPrefix("--") else { throw UsageError("Missing or duplicate value for \(name).") }
                    index += 1; values[name] = raw[index]
                } else if ["--json","--verbose","--check","--scan","--scroll","--help","--version"].contains(name) {
                    guard flags.insert(name).inserted else { throw UsageError("Duplicate \(name).") }
                } else { throw UsageError("Unknown option '\(word)'. Use --help.") }
            } else { words.append(word) }
            index += 1
        }
    }
    func allow(_ options: Set<String> = []) throws {
        let supplied = flags.union(values.keys)
        let unknown = supplied.subtracting(options.union(["--device","--json","--verbose"]))
        guard unknown.isEmpty else { throw UsageError("Option \(unknown.sorted().joined(separator: ", ")) does not apply to this command.") }
    }
}

enum CLI {
    static func output(_ object: Any, json: Bool, text: String) throws {
        if json {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        } else { print(text) }
    }

    static func run(_ raw: [String]) throws {
        let args = try Arguments(raw)
        verbose = args.flags.contains("--verbose")
        let json = args.flags.contains("--json")
        if args.flags.contains("--version") {
            guard args.words.isEmpty else { throw UsageError("Use ditooctl --version.") }
            print(version); return
        }
        if raw.isEmpty { print(help); return }
        if args.words.first == "help" || args.flags.contains("--help") {
            let command = args.words.first == "help" ? args.words.dropFirst().first : args.words.first
            if let command {
                guard let detail = commandHelp[command] else { throw UsageError("Unknown help topic '\(command)'.") }
                print(detail)
            } else { print(help) }
            return
        }
        guard let command = args.words.first else { throw UsageError("Specify a command; use --help.") }
        let words = Array(args.words.dropFirst())
        if command == "device" { try registry(words, args: args, json: json); return }

        // All argument and media validation happens before touching Bluetooth.
        var media: Media?
        var packets: [[UInt8]] = []
        var uploadCommand: UInt8 = 0x44
        var percent: Int?
        var color: RGB?
        switch command {
        case "status":
            try args.allow(); guard words.isEmpty else { throw UsageError("Use status [--json].") }
        case "brightness":
            try args.allow(); guard words.count <= 1 else { throw UsageError("Use brightness [0...100].") }
            if let word = words.first {
                guard let value = Int(word), (0...100).contains(value) else { throw UsageError("Brightness must be an integer from 0 to 100.") }
                percent = value
            }
        case "mode":
            try args.allow(["--color"])
            guard words.count <= 1 else { throw UsageError("Use mode [MODE] [--color RRGGBB].") }
            if let mode = words.first, !["clock","light","gallery","visualizer","custom","off"].contains(mode) { throw UsageError("Mode must be clock, light, gallery, visualizer, custom, or off.") }
            if let value = args.values["--color"] {
                guard words.first == "clock" || words.first == "light" else { throw UsageError("--color applies only to mode clock or mode light.") }
                color = try RGB(hex: value)
            }
        case "show":
            try args.allow(["--check"]); guard words.count == 1 else { throw UsageError("Use show FILE [--check].") }
            let decoded = try Media(path: words[0]); media = decoded
            if args.flags.contains("--check") {
                var info = decoded.info; info["bluetooth_accessed"] = false
                try output(info, json: json, text: "Valid \(decoded.format.uppercased()): 16×16, \(decoded.durations.count) frame(s), \(decoded.durations.reduce(0,+)) ms cycle, \(info["encoded_bytes"]!) encoded bytes. No upload.")
                return
            }
            packets = decoded.packets; uploadCommand = decoded.command
        case "text":
            try args.allow(["--scroll","--color"]); guard words.count == 1 else { throw UsageError("Use text TEXT [--scroll] [--color RRGGBB]; quote TEXT.") }
            let input = words[0]
            guard input.unicodeScalars.allSatisfy({ $0.isASCII }) else { throw UsageError("Text supports ASCII A–Z, 0–9, spaces, - . !") }
            let ink = try args.values["--color"].map { try RGB(hex:$0) } ?? RGB(255,255,255)
            if args.flags.contains("--scroll") {
                _ = try label(input, offset:16, color:ink)
                let end = -(input.count * 4)
                let step = max(1, Int(ceil(Double(16 - end) / 59.0)))
                var offsets = Array(stride(from:16, through:end, by:-step))
                if offsets.last != end { offsets.append(end) }
                let frames = try offsets.map { try label(input, offset:$0, color:ink) }
                packets = try Divoom.animation(frames, milliseconds:130 * step); uploadCommand = 0x49
            } else { packets = [try Divoom.image(label(input, color:ink))] }
        default: throw UsageError("Unknown command '\(command)'. Use --help.")
        }

        let selected = try DeviceStore().resolve(args.values["--device"])
        let deadline = CommandDeadline()
        defer { deadline.cancel() }
        try BluetoothAccess.require()
        // Do not create an unpaired IOBluetoothDevice and ask for its name: that
        // lookup can hang while resolving a remote address. Pairing is explicit.
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        guard let device = paired.first(where: {
            guard let raw = $0.addressString else { return false }
            return (try? normalizedAddress(raw)) == selected.address
        }) else {
            throw DivoomError("\(selected.address) is not paired on this Mac. Run 'ditooctl device pair \(selected.name ?? selected.address)' or pair Ditoo-audio in System Settings → Bluetooth.")
        }
        guard (device.name ?? "").lowercased().contains("ditoo") else {
            throw DivoomError("\(selected.address) is not identified as a Ditoo on this Mac. Pair it in System Settings → Bluetooth, then retry.")
        }
        let connection = Connection(device:device)
        defer { connection.close() }
        try connection.open()
        let identity: [String:Any] = ["name":selected.name as Any? ?? NSNull(),"address":selected.address,"bluetooth_name":device.name as Any? ?? NSNull()]
        switch command {
        case "status", "mode":
            let report: DisplayReport
            if command == "mode", let mode = words.first { report = try setMode(mode, color:color, connection:connection) }
            else { report = try readDisplay(connection) }
            var result = report.json
            result["device"] = identity; result["connected"] = true
            var lines = ["\(selected.name ?? device.name ?? "Ditoo")  \(selected.address)","Mode: \(report.mode)"]
            if command == "status" { lines.append("Brightness: \(report.brightness.map(String.init) ?? "unknown")") }
            for key in report.settings.keys.sorted() { lines.append("\(key): \(report.settings[key]!)") }
            try output(result,json:json,text:lines.joined(separator:"\n"))
        case "brightness":
            if let percent {
                // Some firmware replies using 0x31, so confirm through the settings query.
                try connection.send(Divoom.brightness(percent),settle:0.2)
            }
            let report = try readDisplay(connection)
            guard let actual = report.brightness else { throw DivoomError("Device returned an unknown brightness value.") }
            if let percent, actual != percent { throw DivoomError("Brightness readback was \(actual), expected \(percent).") }
            try output(["device":identity,"brightness":actual],json:json,text:String(actual))
        case "show", "text":
            try upload(packets,command:uploadCommand,connection:connection)
            var result: [String:Any] = ["device":identity,"acknowledged":true,"playback":uploadCommand == 0x49 ? "repeat" : "still"]
            if let media { result["media"] = media.info }
            try output(result,json:json,text:uploadCommand == 0x49 ? "Animation acknowledged; playback repeats on the device." : "Image acknowledged.")
        default: break
        }
    }

    static func registry(_ words: [String], args: Arguments, json: Bool) throws {
        try args.allow(["--scan"])
        guard args.values["--device"] == nil else { throw UsageError("--device does not apply to device registry commands.") }
        guard let action = words.first else { throw UsageError("Use device list|add|pair|use|remove. See device --help.") }
        if args.flags.contains("--scan"), action != "list" { throw UsageError("--scan applies only to device list.") }
        let store = try DeviceStore()
        if action == "pair" {
            guard words.count <= 2 else { throw UsageError("Use device pair [NAME_OR_ADDRESS]. Omit the target to pair the default device.") }
            let selected = try store.resolve(words.dropFirst().first)
            let deadline = CommandDeadline()
            defer { deadline.cancel() }
            try BluetoothAccess.require()
            let device = try deviceAt(selected.address)
            let alreadyPaired = try Pairing().run(device, address: selected.address)
            try output(["action": "pair", "name": selected.name as Any? ?? NSNull(),
                        "address": selected.address, "paired": true, "already_paired": alreadyPaired],
                       json: json, text: "\(alreadyPaired ? "Already paired" : "Paired"): \(selected.name ?? selected.address) on this Mac.")
            return
        }
        var config = try store.read()
        switch action {
        case "list":
            guard words.count == 1 else { throw UsageError("Use device list [--scan].") }
            let deadline = CommandDeadline()
            defer { deadline.cancel() }
            try BluetoothAccess.require()
            let inventory: [IOBluetoothDevice]
            if args.flags.contains("--scan") { inventory = try Discovery().run(seconds:8, all:false, printResults:false) }
            else { inventory = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter(candidate) }
            var byAddress: [String:IOBluetoothDevice] = [:]
            for device in inventory {
                if let raw = device.addressString, let address = try? normalizedAddress(raw) { byAddress[address] = device }
            }
            let addresses = Set(config.devices.values).union(byAddress.keys).sorted()
            var rows: [[String:Any]] = []
            var lines: [String] = []
            for address in addresses {
                let names = config.devices.filter { $0.value == address }.keys.sorted()
                let device = byAddress[address]
                for name in names.isEmpty ? [nil] : names.map(Optional.some) {
                    let isDefault = name != nil && name == config.defaultDevice
                    rows.append(["name":name as Any? ?? NSNull(),"address":address,"default":isDefault,
                                 "bluetooth_name":device?.name as Any? ?? NSNull(),
                                 "paired":device.map { $0.isPaired() } as Any? ?? NSNull(),
                                 "connected":device.map { $0.isConnected() } as Any? ?? NSNull()])
                    lines.append("\(isDefault ? "*" : " ") \(name ?? "(unsaved)")  \(address)  \(device?.name ?? "not in macOS inventory")")
                }
            }
            try output(["default_device":config.defaultDevice as Any? ?? NSNull(),"devices":rows],json:json,text:lines.isEmpty ? "No saved or paired Ditoos. Use device list --scan." : lines.joined(separator:"\n"))
            return
        case "add":
            guard words.count == 3, validDeviceName(words[1]) else { throw UsageError("Use device add NAME ADDRESS; names use 1–64 letters/digits, '-' or '_'.") }
            guard config.devices[words[1]] == nil else { throw UsageError("Device name '\(words[1])' already exists.") }
            config.devices[words[1]] = try normalizedAddress(words[2])
            if config.defaultDevice == nil { config.defaultDevice = words[1] }
        case "use", "remove":
            guard words.count == 2, config.devices[words[1]] != nil else { throw UsageError("Use device \(action) NAME with a saved name.") }
            if action == "use" { config.defaultDevice = words[1] }
            else {
                config.devices.removeValue(forKey:words[1])
                if config.defaultDevice == words[1] { config.defaultDevice = nil }
            }
        default: throw UsageError("Unknown device action '\(action)'. Use device --help.")
        }
        try store.write(config)
        try output(["action":action,"name":words[1],"default_device":config.defaultDevice as Any? ?? NSNull()],json:json,text:"Device \(action): \(words[1]). Default: \(config.defaultDevice ?? "none").")
    }
}
