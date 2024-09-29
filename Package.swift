// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "root",
  platforms: [.macOS(.v15)],

  dependencies: [
    .package(url: "https://github.com/vapor/vapor.git", from: "4.105.2"),
  ],

  targets: [
    .executableTarget(
      name: "ocrd",

      dependencies: [
        .product(name: "Vapor", package: "vapor"),
      ],

      swiftSettings: [
        .unsafeFlags(["-cross-module-optimization", "-whole-module-optimization"], .when(configuration: .release))
      ]
    ),
  ]
)