import Foundation
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
    func findCxxIncludePath() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !output.isEmpty
            {
                return "\(output)/usr/include/c++/v1"
            }
        } catch {}
        return
            "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/c++/v1"
    }

    let cxxUnsafeFlags = [
        "-Xcc", "-std=c++2b",
        "-Xcc", "-isystem",
        "-Xcc", findCxxIncludePath(),
    ]
    let stdLib = "c++"
#else
    let cxxUnsafeFlags = [
        "-Xcc", "-std=c++2b",
    ]
    let stdLib = "stdc++"
#endif

let package = Package(
    name: "Vsexpr",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Vsexpr", targets: ["Vsexpr"])
    ],
    dependencies: [
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "VsexprLib",
            cxxSettings: cxxSettings,
            linkerSettings: [
                .linkedLibrary(stdLib)
            ]
        ),
        .target(
            name: "Vsexpr",
            dependencies: ["VsexprLib"],
            swiftSettings: swiftSettings + [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(cxxUnsafeFlags),
            ]
        ),
        .testTarget(
            name: "VsexprTests",
            dependencies: [
                "Vsexpr",
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
