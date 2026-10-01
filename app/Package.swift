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
    ),
    .testTarget(
      name: "COGLF1Tests",
      dependencies: ["COGLF1"],
      path: "Tests/COGLF1Tests"
    ),
  ]
)
