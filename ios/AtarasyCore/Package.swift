// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AtarasyCore", defaultLocalization: "en", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "AtarasyCore", targets: ["AtarasyCore"])], targets: [.target(name: "AtarasyCore", resources: [.process("Resources")]), .testTarget(name: "AtarasyCoreTests", dependencies: ["AtarasyCore"], resources: [.copy("Fixtures")])])
