// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParagraphTranslator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ParagraphTranslator", targets: ["ParagraphTranslator"]),
        .library(name: "TranslatorCore", targets: ["TranslatorCore"])
    ],
    targets: [
        .target(name: "TranslatorCore"),
        .executableTarget(name: "ParagraphTranslator", dependencies: ["TranslatorCore"]),
        .testTarget(name: "TranslatorCoreTests", dependencies: ["TranslatorCore"])
    ],
    swiftLanguageModes: [.v5]
)
