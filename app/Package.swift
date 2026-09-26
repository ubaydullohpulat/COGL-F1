// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "COGLF1",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "COGLF1",
      path: "Sources/COGLF1",
      exclude: ["Resources"]
    )
  ]
)
