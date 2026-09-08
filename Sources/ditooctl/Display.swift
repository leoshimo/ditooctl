import Foundation
import DivoomProtocol

struct DisplayReport {
    let data: [UInt8]
    init(_ data: [UInt8]) throws {
        guard data.count == 20 || data.count == 22 else { throw DivoomError("Unrecognized settings reply (\(data.count) bytes); no values were guessed.") }
        self.data = data
    }
    var mode: String {
        // The Sun-key blank position is an extra selector, not base mode 6.
        if data.count == 22 && data[20] == 6 { return "off" }
        if data[0] == 1 && data[8] == 0 { return "off" }
        return [0:"clock",1:"light",2:"gallery",3:"effects",4:"visualizer",5:"custom",6:"lyrics"][data[0]] ?? "unknown"
    }
    var brightness: Int? { data[10] <= 100 ? Int(data[10]) : nil }
    func color(_ start: Int) -> String { Array(data[start...start+2]).hex.uppercased() }
    var settings: [String: Any] {
        switch data[0] {
        case 0:
            return ["color":color(12), "style":Int(data[15]),
                    "time_format":data[11] <= 1 ? (data[11] == 1 ? "24h" : "12h") as Any : NSNull(),
                    "show_clock":flag(16), "show_weather":flag(17), "show_temperature":flag(18), "show_calendar":flag(19)]
        case 1: return ["color":color(3),"brightness":Int(data[6]),"effect":Int(data[7]),"enabled":flag(8)]
        case 4: return ["effect":Int(data[9])]
        case 3: return ["effect":Int(data[2])]
        default: return [:]
        }
    }
    private func flag(_ index: Int) -> Any { data[index] <= 1 ? (data[index] == 1) as Any : NSNull() }
    var json: [String: Any] { ["mode":mode,"brightness":brightness as Any? ?? NSNull(),"settings":settings] }
}

func readDisplay(_ connection: Connection) throws -> DisplayReport {
    try DisplayReport(requestReply(connection, packet: Divoom.packet([0x46]), command: 0x46).data)
}

func setMode(_ mode: String, color: RGB?, connection: Connection) throws -> DisplayReport {
    let before = try readDisplay(connection)
    var d = before.data
    let packet: [UInt8]
    let expected: UInt8
    switch mode {
    case "clock":
        if let color { d.replaceSubrange(12...14, with: [color.r,color.g,color.b]) }
        packet = try Divoom.clock(viewData: d); expected = 0
    case "light", "off":
        if let color { d.replaceSubrange(3...5, with: [color.r,color.g,color.b]) }
        // An off night-light gives a blank screen while preserving its RGB,
        // brightness, and effect. It does not turn off the speaker/device.
        d[8] = mode == "off" ? 0 : 1
        packet = try Divoom.packet([0x45,1] + Array(d[3...8])); expected = 1
    case "gallery": packet = try Divoom.packet([0x45,2]); expected = 2
    case "visualizer": packet = try Divoom.packet([0x45,4,d[9]]); expected = 4
    case "custom": packet = try Divoom.packet([0x45,5]); expected = 5
    default: throw UsageError("Mode must be clock, light, gallery, visualizer, custom, or off.")
    }
    let ack = try requestReply(connection, packet: packet, command: 0x45)
    guard ack.data == [expected] else { throw DivoomError("Device did not confirm the requested mode.") }
    let after = try readDisplay(connection)
    guard after.data[0] == expected else { throw DivoomError("Mode readback differs from the request.") }
    if mode == "clock", Array(after.data[11...19]) != Array(d[11...19]) {
        throw DivoomError("Clock settings readback differs from the request.")
    }
    if mode == "light" || mode == "off", Array(after.data[3...8]) != Array(d[3...8]) {
        throw DivoomError("Light settings readback differs from the request.")
    }
    if mode == "visualizer", after.data[9] != d[9] { throw DivoomError("Visualizer selection was not preserved.") }
    return after
}

func upload(_ packets: [[UInt8]], command: UInt8, connection: Connection) throws {
    var acknowledged = false
    let previous = connection.onReply
    connection.onReply = { reply in
        previous?(reply)
        if reply.command == command { acknowledged = true }
    }
    defer { connection.onReply = previous }
    for (index, packet) in packets.enumerated() {
        // A reply to an earlier chunk cannot confirm the final chunk.
        if index == packets.count - 1 { acknowledged = false }
        try connection.send(packet, settle: index == packets.count - 1 ? 0.2 : 0.08)
    }
    _ = pump(seconds: 3) { acknowledged || connection.closed }
    guard acknowledged else { throw DivoomError("Upload was written but not acknowledged; the display may have changed. It was not retried.") }
}
