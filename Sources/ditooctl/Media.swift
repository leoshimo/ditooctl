import Foundation
import AppKit
import ImageIO
import DivoomProtocol

struct DecodedAnimation {
    let packets: [[UInt8]]
    let durations: [Int]
    var info: [String: Any] {
        ["valid":true, "width":16, "height":16, "frames":durations.count,
         "frame_durations_ms":durations, "cycle_ms":durations.reduce(0,+),
         "encoded_bytes":packets.reduce(0) { $0 + $1.count - 10 },
         "packets":packets.count, "playback":"repeat", "bluetooth_accessed":false]
    }
}

func readImage(_ path: String) throws -> [RGB] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide == 16, bitmap.pixelsHigh == 16 else {
        throw DivoomError("Image must be a supported 16×16 bitmap (PNG recommended). Resize it first.")
    }
    return try readPixels(bitmap)
}

func readPixels(_ bitmap: NSBitmapImageRep) throws -> [RGB] {
    guard bitmap.pixelsWide == 16, bitmap.pixelsHigh == 16 else { throw DivoomError("Each frame must be exactly 16×16.") }
    var pixels: [RGB] = []
    for y in 0..<16 { for x in 0..<16 {
        guard let source = bitmap.colorAt(x: x, y: y),
              let color = source.colorSpace.colorSpaceModel == .rgb ? source : source.usingColorSpace(.sRGB) else { throw DivoomError("Unable to read RGB pixels.") }
        func component(_ n: CGFloat) -> UInt8 { UInt8(max(0, min(255, (n * color.alphaComponent * 255).rounded()))) }
        pixels.append(RGB(component(color.redComponent), component(color.greenComponent), component(color.blueComponent)))
    } }
    return pixels
}

func readAnimation(_ path: String) throws -> DecodedAnimation {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let type = CGImageSourceGetType(source), type as String == "com.compuserve.gif" else {
        throw DivoomError("Expected a 16×16 GIF file.")
    }
    let count = CGImageSourceGetCount(source)
    guard (1...60).contains(count) else { throw DivoomError("GIF must contain 1...60 frames.") }
    var frames: [[RGB]] = []
    var durations: [Int] = []
    for index in 0..<count {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw DivoomError("Cannot decode GIF frame \(index).") }
        frames.append(try readPixels(NSBitmapImageRep(cgImage: image)))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
        guard seconds.isFinite, seconds >= 0, seconds <= 65.535 else { throw DivoomError("GIF frame duration is out of range.") }
        durations.append(seconds == 0 ? 100 : max(10, Int((seconds * 1000).rounded())))
    }
    trace("Decoded \(count) GIF frames; cycle \(durations.reduce(0,+)) ms.")
    return DecodedAnimation(packets:try Divoom.animation(frames, durations: durations), durations:durations)
}

struct Media {
    let format: String
    let packets: [[UInt8]]
    let durations: [Int]
    var command: UInt8 { format == "gif" ? 0x49 : 0x44 }
    var info: [String: Any] {
        ["valid":true, "format":format, "width":16, "height":16,
         "frames":durations.count, "frame_durations_ms":durations,
         "cycle_ms":durations.reduce(0,+),
         "encoded_bytes":packets.reduce(0) { $0 + $1.count - (format == "gif" ? 10 : 11) },
         "packets":packets.count, "playback":format == "gif" ? "repeat" : "still"]
    }
    init(path: String) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw UsageError("Cannot open media. Use a 16×16 PNG or GIF.") }
        switch type as String {
        case "public.png":
            guard CGImageSourceGetCount(source) == 1 else { throw UsageError("Animated PNG is not supported. Use GIF for animations.") }
            format = "png"; durations = [0]; packets = [try Divoom.image(readImage(path))]
        case "com.compuserve.gif":
            let decoded = try readAnimation(path)
            format = "gif"; durations = decoded.durations; packets = decoded.packets
        default: throw UsageError("Unsupported media format. Use PNG or GIF; see 'ditooctl show --help'.")
        }
    }
}

func preview(_ pixels: [RGB], at path: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 48, bitsPerPixel: 24), let data = bitmap.bitmapData else { throw DivoomError("Unable to create PNG.") }
    for (i, p) in pixels.enumerated() { data[i * 3] = p.r; data[i * 3 + 1] = p.g; data[i * 3 + 2] = p.b }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DivoomError("Unable to encode PNG.") }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    log("Preview written: \(path)")
}
