// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Necto",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "NectoSDK", targets: ["NectoSDK"]),
        .library(name: "NectoNetworkPlugin", targets: ["NectoNetworkPlugin"]),
        .library(name: "NectoEventsPlugin", targets: ["NectoEventsPlugin"]),
        .library(name: "NectoFilesPlugin", targets: ["NectoFilesPlugin"]),
        .library(name: "NectoPreferencesPlugin", targets: ["NectoPreferencesPlugin"]),
        .library(name: "NectoPerformancePlugin", targets: ["NectoPerformancePlugin"]),
        .library(name: "NectoUIControlPlugin", targets: ["NectoUIControlPlugin"]),
        .library(name: "NectoDefaultPlugin", targets: ["NectoDefaultPlugin"]),
        .library(name: "NectoProcessMetricPlugin", targets: ["NectoProcessMetricPlugin"]),
        .library(name: "NectoURLSessionCapturePlugin", targets: ["NectoURLSessionCapturePlugin"]),
    ],
    targets: [
        .target(name: "NectoModel"),
        .target(
            name: "NectoTransport"
        ),
        .target(
            name: "NectoSDK",
            dependencies: ["NectoModel", "NectoTransport"]
        ),
        .target(
            name: "NectoNetworkPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoEventsPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoFilesPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoPreferencesPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoPerformancePlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoUIControlPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoDefaultPlugin",
            dependencies: [
                "NectoNetworkPlugin",
                "NectoEventsPlugin",
                "NectoFilesPlugin",
                "NectoPreferencesPlugin",
                "NectoPerformancePlugin",
                "NectoUIControlPlugin",
            ]
        ),
        // CPU, memory and frame-rate capture for apps that explicitly opt in.
        .target(
            name: "NectoProcessMetricPlugin",
            dependencies: ["NectoPerformancePlugin", "NectoModel", "NectoSDK"]
        ),
        // Capture stays separate from the reporting API and starts only on registration.
        .target(
            name: "NectoURLSessionCapturePlugin",
            dependencies: ["NectoNetworkPlugin", "NectoModel", "NectoSDK"]
        ),
        .testTarget(
            name: "NectoModelTests",
            dependencies: ["NectoModel"]
        ),
        .testTarget(
            name: "NectoTransportTests",
            dependencies: ["NectoTransport"]
        ),
        .testTarget(
            name: "NectoSDKTests",
            dependencies: [
                "NectoSDK", "NectoDefaultPlugin", "NectoProcessMetricPlugin", "NectoTransport", "NectoModel",
                "NectoNetworkPlugin", "NectoEventsPlugin", "NectoFilesPlugin", "NectoPreferencesPlugin",
                "NectoPerformancePlugin", "NectoUIControlPlugin",
            ]
        ),
        .testTarget(
            name: "NectoURLSessionCaptureTests",
            dependencies: ["NectoURLSessionCapturePlugin", "NectoNetworkPlugin", "NectoModel"]
        ),
        .testTarget(
            name: "NectoProcessMetricsTests",
            dependencies: ["NectoProcessMetricPlugin", "NectoPerformancePlugin", "NectoSDK", "NectoModel"]
        ),
    ]
)
