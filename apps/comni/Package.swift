// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Comni",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "ComniDomain", targets: ["ComniDomain"]),
    .library(name: "ComniRuntime", targets: ["ComniRuntime"]),
    .library(name: "ComniMedia", targets: ["ComniMedia"]),
    .executable(name: "ComniApp", targets: ["ComniApp"]),
    .executable(name: "ComniProbe", targets: ["ComniProbe"]),
  ],
  targets: [
    .target(name: "ComniDomain"),
    .target(
      name: "ComniRuntime",
      dependencies: ["ComniDomain"]
    ),
    .target(
      name: "ComniMedia",
      dependencies: ["ComniDomain"],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreImage"),
      ]
    ),
    .executableTarget(
      name: "ComniApp",
      dependencies: [
        "ComniDomain",
        "ComniRuntime",
        "ComniMedia",
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AVFoundation"),
      ]
    ),
    .executableTarget(
      name: "ComniProbe",
      dependencies: ["ComniDomain", "ComniRuntime"],
      linkerSettings: [
        .linkedFramework("CoreImage")
      ]
    ),
    .testTarget(
      name: "ComniDomainTests",
      dependencies: ["ComniDomain"]
    ),
    .testTarget(
      name: "ComniRuntimeTests",
      dependencies: ["ComniDomain", "ComniRuntime"]
    ),
  ]
)
