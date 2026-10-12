// swift-tools-version: 6.0
import PackageDescription
import Foundation
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "MacXTerm",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacXTermCore", targets: ["MacXTermCore"]),
        .executable(name: "MacXTerm", targets: ["MacXTermApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/Lakr233/openssl-spm.git", exact: "3.6.2"),
    ],
    targets: [
        .target(
            name: "CLibSSH2", dependencies: [.product(name: "OpenSSL", package: "openssl-spm")],
            exclude: [
                "LICENSE", "src/CMakeLists.txt", "src/Makefile.am", "src/Makefile.inc", "src/libssh2.rc",
                "src/libssh2_config_cmake.h.in",
            ],
            sources: ["src"], publicHeadersPath: "include",
            cSettings: [
                "LIBSSH2_OPENSSL", "HAVE_LIBSSL", "HAVE_LIBZ", "LIBSSH2_HAVE_ZLIB", "STDC_HEADERS", "HAVE_STDLIB_H",
                "HAVE_STDIO_H", "HAVE_INTTYPES_H", "HAVE_UNISTD_H", "HAVE_ALLOCA", "HAVE_ALLOCA_H", "HAVE_ARPA_INET_H",
                "HAVE_NETINET_IN_H", "HAVE_SYS_SOCKET_H", "HAVE_SYS_UN_H", "HAVE_SYS_IOCTL_H", "HAVE_SYS_PARAM_H",
                "HAVE_SYS_SELECT_H", "HAVE_SYS_UIO_H", "HAVE_SYS_TIME_H", "HAVE_GETTIMEOFDAY", "HAVE_SELECT",
                "HAVE_SNPRINTF", "HAVE_STRTOLL", "HAVE_O_NONBLOCK", "HAVE_FIONBIO",
            ].map { .define($0) },
            linkerSettings: [.linkedLibrary("z")]),
        .target(name: "SSHBridge", dependencies: ["CLibSSH2"]),
        .target(name: "RDPBridge", dependencies: [.product(name: "OpenSSL", package: "openssl-spm")],
            cSettings: [.headerSearchPath("../../Vendor/FreeRDP/include/freerdp3"),
                        .headerSearchPath("../../Vendor/FreeRDP/include/winpr3")],
            linkerSettings: [.unsafeFlags(["-L", packageRoot + "/Vendor/FreeRDP/lib"]),
                .linkedLibrary("freerdp3"), .linkedLibrary("winpr3"), .linkedLibrary("z"),
                .linkedFramework("Security"), .linkedFramework("SystemConfiguration")]),
        .target(name: "MacXTermCore", dependencies: ["SSHBridge", "RDPBridge"]),
        .executableTarget(
            name: "MacXTermApp", dependencies: ["MacXTermCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"), .process("Resources/Localizable.xcstrings"),
                .copy("Resources/ThirdPartyNotices.txt"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/ByPyBridge.py"),
            ]),
        .testTarget(name: "MacXTermCoreTests", dependencies: ["MacXTermCore"]),
        .testTarget(name: "MacXTermAppTests", dependencies: ["MacXTermApp"]),
    ],
    swiftLanguageModes: [.v6]
)
