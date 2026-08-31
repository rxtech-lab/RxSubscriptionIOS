// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RxSubscriptionIOS",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
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
