// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "ditooctl",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ditooctl", targets: ["ditooctl"])],
    targets: [
        .target(name: "DivoomProtocol"),
        .executableTarget(name: "ditooctl", dependencies: ["DivoomProtocol"],
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("AppKit"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", root + "/Info.plist"])])
    ]
)
