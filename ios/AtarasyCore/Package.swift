// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AtarasyCore", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "AtarasyCore", targets: ["AtarasyCore"])], targets: [.target(name: "AtarasyCore"), .testTarget(name: "AtarasyCoreTests", dependencies: ["AtarasyCore"], resources: [.copy("Fixtures")])])
