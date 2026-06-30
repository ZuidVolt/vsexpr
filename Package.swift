// swift-tools-version: 6.3
import PackageDescription

let cxxSettings: [CXXSetting] = [
    .headerSearchPath("include"),
    .unsafeFlags([
        "-std=c++2b",
        "-fno-exceptions",
        "-fno-caret-diagnostics",
        "-fno-diagnostics-color",
        "-fno-elide-type",
        "-fdiagnostics-show-option",
        "-Wreturn-type",
        "-ftemplate-backtrace-limit=2",
        "-Werror=return-stack-address",
        "-Werror=dangling",
        "-Wconversion",
        "-Wsign-conversion",
        "-Wshorten-64-to-32",
        "-Wimplicit-int-float-conversion",
        "-Wfloat-conversion",
        "-Wnullability",
        "-Wnullability-completeness",
        "-Wnullability-extension",
        "-Wno-nullability-inferred-on-nested-type",
        "-Wnullable-to-nonnull-conversion",
        "-Werror=switch",
        "-Wmove",
        "-Wnrvo",
        "-O3",
        "-ffast-math",
    ]),
]

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

#if os(macOS)
    let cxxUnsafeFlags = [
        "-Xcc", "-std=c++2b",
        "-Xcc", "-isystem",
        "-Xcc",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/c++/v1",
    ]
#else
    let cxxUnsafeFlags = [
        "-Xcc", "-std=c++2b",
    ]
#endif

let package = Package(
    name: "vsexpr",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "vsexpr", targets: ["vsexpr"])
    ],
    dependencies: [
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "vsexprLib",
            cxxSettings: cxxSettings,
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "vsexpr",
            dependencies: ["vsexprLib"],
            swiftSettings: swiftSettings + [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(cxxUnsafeFlags),
            ]
        ),
        .testTarget(
            name: "vsexprTests",
            dependencies: [
                "vsexpr",
                .product(name: "PropertyBased", package: "swift-property-based"),
            ],
            swiftSettings: swiftSettings + [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(cxxUnsafeFlags),
            ]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx2b
)
