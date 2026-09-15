// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Fieldnotes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FieldnotesCore", targets: ["FieldnotesCore"]),
        .executable(name: "FieldnotesApp", targets: ["FieldnotesApp"]),
        .executable(name: "fieldnotes", targets: ["FieldnotesCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            exact: "6.2.3"
        ),
    ],
    targets: [
        .target(name: "FieldnotesCore"),
        .executableTarget(
            name: "FieldnotesApp",
            dependencies: ["FieldnotesCore"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(name: "FieldnotesCLI", dependencies: ["FieldnotesCore"]),
        .testTarget(
            name: "FieldnotesAppTests",
            dependencies: [
                "FieldnotesApp",
                "FieldnotesCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
