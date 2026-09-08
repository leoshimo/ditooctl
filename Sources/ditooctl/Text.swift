import Foundation
import Darwin
import DivoomProtocol

// Tiny hand-authored 3×5 glyphs keep short labels and counters legible at 16×16.
let glyphs: [Character: [Int]] = [
    "A":[2,5,7,5,5], "B":[6,5,6,5,6], "C":[3,4,4,4,3], "D":[6,5,5,5,6],
    "E":[7,4,6,4,7], "F":[7,4,6,4,4], "G":[3,4,5,5,3], "H":[5,5,7,5,5],
    "I":[7,2,2,2,7], "J":[1,1,1,5,2], "K":[5,5,6,5,5], "L":[4,4,4,4,7],
    "M":[5,7,7,5,5], "N":[5,7,7,7,5], "O":[2,5,5,5,2], "P":[6,5,6,4,4],
    "Q":[2,5,5,3,1], "R":[6,5,6,5,5], "S":[3,4,2,1,6], "T":[7,2,2,2,2],
    "U":[5,5,5,5,7], "V":[5,5,5,5,2], "W":[5,5,7,7,5], "X":[5,5,2,5,5],
    "Y":[5,5,2,2,2], "Z":[7,1,2,4,7], "0":[7,5,5,5,7], "1":[2,6,2,2,7],
    "2":[6,1,2,4,7], "3":[6,1,2,1,6], "4":[5,5,7,1,1], "5":[7,4,6,1,6],
    "6":[3,4,6,5,2], "7":[7,1,2,2,2], "8":[2,5,2,5,2], "9":[2,5,3,1,6],
    " ":[0,0,0,0,0], "-" :[0,0,7,0,0], ".":[0,0,0,0,2], "!": [2,2,2,0,2]
]

func label(_ text: String, offset: Int? = nil, color: RGB = RGB(255,255,255)) throws -> [RGB] {
    let chars = Array(text.uppercased())
    guard !chars.isEmpty, chars.count <= 40, chars.allSatisfy({ glyphs[$0] != nil }) else {
        throw DivoomError("Use 1...40 characters: A–Z, 0–9, spaces, - . !")
    }
    if offset == nil && chars.count > 4 { throw DivoomError("Static text fits up to 4 characters. Use scroll for longer text.") }
    let width = chars.count * 4 - 1
    let scale = offset == nil && width <= 7 ? 2 : 1
    let origin = offset ?? (16 - width * scale) / 2
    let top = (16 - 5 * scale) / 2
    var pixels = [RGB](repeating: .black, count: 256)
    for (i, character) in chars.enumerated() {
        for (y, row) in glyphs[character]!.enumerated() {
            for x in 0..<3 where row & (1 << (2-x)) != 0 {
                for dy in 0..<scale { for dx in 0..<scale {
                    let px = origin + (i*4+x)*scale + dx
                    let py = top + y*scale + dy
                    if (0..<16).contains(px) { pixels[py*16+px] = color }
                } }
            }
        }
    }
    return pixels
}

func orbitFrames() -> [[RGB]] {
    let points = [(3,3),(7,3),(11,3),(11,7),(11,11),(7,11),(3,11),(3,7)]
    return points.map { x, y in
        var pixels = [RGB](repeating: .black, count: 256)
        for dx in 0...1 { for dy in 0...1 { pixels[(y+dy)*16+x+dx] = RGB(0,72,44) } }
        pixels[7*16+7] = RGB(25,12,0)
        return pixels
    }
}
