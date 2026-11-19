// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Seatbay",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared code: process inspection, Info.plist keys, paths.
        .target(name: "SeatbayCore", path: "Sources/SeatbayCore"),
        // Tiny launcher copied into every generated instance app.
        .executableTarget(name: "seatbay-launcher", dependencies: ["SeatbayCore"], path: "Sources/Launcher"),
        // The manager app (SwiftUI) and its command line.
        .executableTarget(name: "Seatbay", dependencies: ["SeatbayCore"], path: "Sources/Seatbay"),
        .testTarget(name: "SeatbayTests", dependencies: ["Seatbay", "SeatbayCore"], path: "Tests/SeatbayTests"),
    ]
)
