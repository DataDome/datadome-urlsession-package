// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DataDomeURLSession",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "DataDomeURLSession",
            targets: ["DataDomeURLSession"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/DataDome/mobile-package-ios-coredatadome.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "DataDomeURLSession",
            dependencies: [
                .product(name: "CoreDataDome", package: "mobile-package-ios-coredatadome"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "DataDomeURLSessionTests",
            dependencies: ["DataDomeURLSession"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
