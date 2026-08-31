// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RxSubscriptionIOS",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "RxSubscriptionIOS", targets: ["RxSubscriptionIOS"]),
    ],
    targets: [
        .target(name: "RxSubscriptionIOS"),
        .testTarget(
            name: "RxSubscriptionIOSTests",
            dependencies: ["RxSubscriptionIOS"]
        ),
    ]
)
