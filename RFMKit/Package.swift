// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMKit: libremotefm1 (vendor/RemoteFM1) and FM1VST's CoreMIDI back end (vendor/FM1VST), in place through the vendor symlink,
// RemoteLink (a copy, RFMCore/RemoteLink.h says what changed), the AUv3's render kernel and M2's probes, and the Swift
// API the app and the extension use. FM1Kit (MIT, github.com/ocean/FM1Kit): installing RemoteFM1 on the FM-1 (Install/).
import PackageDescription

let rfm = "RemoteFM1"                   // inside vendor: RemoteFM1 0.3 (standalone, fa97a90: MIDI_IN), its own submodule
let vendorRFM = "../../vendor/RemoteFM1"                 // the same, from Sources/RFMCore
let vendorFM1 = "../../vendor/FM1VST"                    // FM1VST, from Sources/RFMCore

let package = Package(
    name: "RFMKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RFMKit", targets: ["RFMKit"]),
    ],
    dependencies: [
        // 0.4.x fixes, not 0.5 (FM1Kit's minor versions may change its API before 1.0)
        .package(url: "https://github.com/ocean/FM1Kit.git", .upToNextMinor(from: "0.4.5")),
    ],
    targets: [
        // libremotefm1 (portable C99), RemoteFM1's macOS glue (host.c) and FM1VST's CoreMIDI back end
        // (plugin/RemoteMidi.c: HELLO only to FM-1 candidates). No libusb on iOS: usb.c is built with RFM_NO_LIBUSB,
        // which leaves only its stubs (host.c links against them), as FM1VST does without libusb.
        .target(
            name: "CRemoteFM1",
            path: "vendor",
            sources: [
                "\(rfm)/host/src/codec.c",
                "\(rfm)/host/src/fake.c",
                "\(rfm)/host/src/panel.c",
                "\(rfm)/host/src/screen.c",
                "\(rfm)/host/src/session.c",
                "\(rfm)/host/src/tiles_ref.c",
                "\(rfm)/host/src/macos/host.c",
                "\(rfm)/host/src/macos/usb.c",
                "FM1VST/plugin/RemoteMidi.c",
            ],
            publicHeadersPath: "\(rfm)/host/include",
            cSettings: [
                .headerSearchPath("\(rfm)/host/include"),
                .headerSearchPath("\(rfm)/proto"),
                .headerSearchPath("\(rfm)/firmware/src"),
                .headerSearchPath("\(rfm)/host/src/macos"),
                .headerSearchPath("FM1VST/plugin"),
                .define("RFM_NO_LIBUSB", to: "1"),
            ],
            linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("CoreFoundation")]
        ),
        // wasm3 v0.5.0 (MIT, Sources/CWasm3/README.md): the interpreter imported .rfm1 firmware runs in (M7). Its release
        // flags in every configuration (its interpreter needs the optimiser's tail calls; DEBUG off: no asserts, no
        // tracing)
        .target(
            name: "CWasm3",
            path: "Sources/CWasm3",
            exclude: ["README.md", "LICENSE"],
            sources: ["bind", "code", "compile", "core", "emit", "env", "exec", "function", "info", "module", "optimize",
                      "parse"].map { "source/m3_\($0).c" },
            publicHeadersPath: "include",
            cSettings: [
                .define("NASSERTS"),
                .unsafeFlags(["-std=gnu11", "-O3", "-UDEBUG", "-fomit-frame-pointer", "-fno-stack-check",
                              "-fno-stack-protector", "-w"]),
            ]
        ),
        // RemoteLink (session thread, event queue, triple buffer), fm1remote's patterns, and the C API for Swift.
        // M3: the slot loader and the core engine (FM1VST's engine/device.cpp in place, FM1Device.cpp; core-api/)
        .target(
            name: "RFMCore",
            dependencies: ["CRemoteFM1", "CWasm3"],
            cxxSettings: [
                .headerSearchPath("../CWasm3/source"),
                .headerSearchPath("\(vendorFM1)/engine"),
                .headerSearchPath("\(vendorFM1)/plugin"),        // RemoteCandidates.h (RFMMidiMap.cpp)
                .headerSearchPath("\(vendorFM1)/core-api"),
                .headerSearchPath("\(vendorRFM)/host/include"),
                .headerSearchPath("\(vendorRFM)/proto"),
                .headerSearchPath("\(vendorRFM)/host/tools/fm1remote"),
                .headerSearchPath("\(vendorRFM)/host/src/macos"),      // mac_priv.h (RFMProbe: cm_scan)
                .define("FM1_REMOTE_NO_BULK", to: "1"),
            ],
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("AVFoundation")]
        ),
        // the UI's fonts (OFL, bundled) and design/tokens.json (a copy; a test keeps the two equal)
        .target(name: "RFMKit", dependencies: ["RFMCore", .product(name: "FM1Kit", package: "FM1Kit")],
                resources: [.copy("Resources/Fonts"), .copy("Resources/tokens.json")]),
        .testTarget(name: "RFMKitTests", dependencies: ["RFMKit", .product(name: "FM1Kit", package: "FM1Kit")],
                    exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c99,
    cxxLanguageStandard: .cxx17
)
