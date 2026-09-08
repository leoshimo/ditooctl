import Foundation

public struct DivoomError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct RGB: Hashable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: String) throws {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let n = UInt32(value, radix: 16) else { throw DivoomError("Color must be RRGGBB, for example 004020.") }
        self.init(UInt8(n >> 16), UInt8((n >> 8) & 255), UInt8(n & 255))
    }
    public static let black = RGB(0, 0, 0)
}

public enum Divoom {
    public static let size = 16
    private static func le16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8((n >> 8) & 255)] }

    // Ditoo-family unescaped SPP envelope. Length includes its own two bytes;
    // checksum is the sum of length bytes + payload, modulo 65536.
    public static func packet(_ payload: [UInt8]) throws -> [UInt8] {
        guard !payload.isEmpty, payload.count <= 65533 else { throw DivoomError("Payload length must be 1...65533 bytes.") }
        let body = le16(payload.count + 2) + payload
        return [0x01] + body + le16(body.reduce(0) { $0 + Int($1) }) + [0x02]
    }

    public static func brightness(_ percent: Int) throws -> [UInt8] {
        guard (0...100).contains(percent) else { throw DivoomError("Brightness must be 0...100.") }
        return try packet([0x74, UInt8(percent)])
    }

    // The short 45 00 form's handling of omitted settings is unverified.
    // Include every clock field from a fresh 46 report, even in another mode.
    public static func clock(viewData d: [UInt8]) throws -> [UInt8] {
        guard d.count == 20 || d.count == 22 else {
            throw DivoomError("Clock selection requires a complete, recognized live settings report.")
        }
        return try packet([0x45, 0, d[11], d[15]] + Array(d[16...19]) + Array(d[12...14]))
    }

    public static func frame(_ pixels: [RGB], milliseconds: Int = 0) throws -> [UInt8] {
        guard (0...65535).contains(milliseconds) else { throw DivoomError("Frame time must be 0...65535 ms.") }
        guard pixels.count == size * size else { throw DivoomError("Expected exactly 256 pixels (16 × 16).") }
        var palette: [RGB] = []
        var lookup: [RGB: Int] = [:]
        let indices: [Int] = pixels.map { color in
            if let index = lookup[color] { return index }
            let index = palette.count
            palette.append(color)
            lookup[color] = index
            return index
        }
        var bits = 1
        while (1 << bits) < palette.count { bits += 1 }
        var packed: [UInt8] = []
        var accumulator = 0
        var used = 0
        for index in indices {
            accumulator |= index << used
            used += bits
            while used >= 8 {
                packed.append(UInt8(accumulator & 255))
                accumulator >>= 8
                used -= 8
            }
        }
        if used > 0 { packed.append(UInt8(accumulator & 255)) }
        let colors = palette.flatMap { [$0.r, $0.g, $0.b] }
        let body: [UInt8] = le16(milliseconds) + [0, UInt8(palette.count & 255)] + colors + packed
        let frame: [UInt8] = [0xaa] + le16(body.count + 3) + body
        return frame
    }

    public static func image(_ pixels: [RGB]) throws -> [UInt8] {
        try packet([0x44, 0, 0x0a, 0x0a, 4] + frame(pixels))
    }

    public static func animation(_ frames: [[RGB]], milliseconds: Int = 200) throws -> [[UInt8]] {
        try animation(frames, durations: Array(repeating: milliseconds, count: frames.count))
    }

    public static func animation(_ frames: [[RGB]], durations: [Int]) throws -> [[UInt8]] {
        guard !frames.isEmpty, frames.count <= 60 else { throw DivoomError("Animation requires 1...60 frames.") }
        guard durations.count == frames.count else { throw DivoomError("Each animation frame needs a duration.") }
        let data = try zip(frames, durations).flatMap { try frame($0.0, milliseconds: $0.1) }
        guard data.count <= 51200 else { throw DivoomError("Animation exceeds 256 packets of 200 bytes.") }
        return try stride(from: 0, to: data.count, by: 200).enumerated().map { index, offset in
            try packet([0x49] + le16(data.count) + [UInt8(index)] + Array(data[offset..<min(data.count, offset + 200)]))
        }
    }

    // A still, low-intensity teal smile. No animation, audio, or brightness change.
    public static func smile() -> [RGB] {
        var pixels = [RGB](repeating: .black, count: 256)
        let teal = RGB(0, 64, 40)
        for y in 4...6 { for x in [4, 5, 10, 11] { pixels[y * 16 + x] = teal } }
        for (x, y) in [(3,9),(4,10),(5,11),(6,12),(7,12),(8,12),(9,12),(10,11),(11,10),(12,9)] {
            pixels[y * 16 + x] = teal
        }
        return pixels
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

public struct Reply {
    public let command: UInt8
    public let data: [UInt8]
}

// RFCOMM is a stream: one callback can contain partial or multiple packets.
public struct ReplyDecoder {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func append(_ bytes: [UInt8]) -> [Reply] {
        buffer += bytes
        var replies: [Reply] = []
        while buffer.count >= 3 {
            guard buffer[0] == 1 else { buffer.removeFirst(); continue }
            let length = Int(buffer[1]) | Int(buffer[2]) << 8
            guard (5...4096).contains(length) else { buffer.removeFirst(); continue }
            let total = length + 4
            guard buffer.count >= total else { break }
            let frame = Array(buffer.prefix(total))
            let sum = frame[1..<(total - 3)].reduce(0) { $0 + Int($1) } & 0xffff
            let checksum = Int(frame[total - 3]) | Int(frame[total - 2]) << 8
            guard frame.last == 2, sum == checksum else { buffer.removeFirst(); continue }
            if frame[3] == 4 && frame[5] == 0x55 {
                replies.append(Reply(command: frame[4], data: Array(frame[6..<(total - 3)])))
            }
            buffer.removeFirst(total)
        }
        return replies
    }
}
