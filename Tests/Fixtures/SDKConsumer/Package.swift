// swift-tools-version: 6.0

// Copyright (c) 2026 Viva Republica, Inc.

import PackageDescription

let package = Package(
    name: "SDKConsumer",
    platforms: [.macOS(.v14), .iOS(.v16)],
    dependencies: [.package(name: "Necto", path: "../../..")],
    targets: [
        .executableTarget(name: "CoreOnly", dependencies: [.product(name: "NectoSDK", package: "Necto")]),
        .executableTarget(name: "NetworkOnly", dependencies: [.product(name: "NectoNetworkPlugin", package: "Necto")]),
        .testTarget(
            name: "SDKConsumerTests",
            dependencies: [
                .product(name: "NectoSDK", package: "Necto"),
                .product(name: "NectoDefaultPlugin", package: "Necto"),
                .product(name: "NectoProcessMetricPlugin", package: "Necto"),
                .product(name: "NectoURLSessionCapturePlugin", package: "Necto"),
            ]
        ),
    ]
)
