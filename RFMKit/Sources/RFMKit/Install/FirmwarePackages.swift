// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A RemoteFM1 package, downloaded and checked before anything reaches the FM-1: its SHA-256 must be the one
// releases.json gives (else it is refused and not kept), FM1Kit must read it as an FM-1 package (FwscPackage checks its
// header, chip, every part's checksum, a firmware and a loader) and its product must be releases.json's identity. A
// checked package is kept in Caches (packages/<file>) and checked again whenever it is used.

import CryptoKit
import FM1Kit
import Foundation

/// a package that passed every check
public struct VerifiedPackage: Sendable {
    public let ref: FirmwarePackageRef
    public let package: FwscPackage
    public var size: Int { package.fileBytes.count }
}

/// why a package was refused
public enum PackageProblem: Error, LocalizedError, Equatable {
    case checksumMismatch(file: String, expected: String, got: String)
    case identityMismatch(file: String, expected: String, got: String)
    case unreadable(file: String, why: String)

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch(let f, _, _):
            "\(f) isn't the file the RemoteFM1 site lists (its SHA-256 differs), so it was not installed. Try again; "
                + "if it keeps happening, the download is being changed on its way."
        case .identityMismatch(let f, let expected, let got):
            "\(f) installs as \(got), not \(expected) as the RemoteFM1 site says, so it was not installed."
        case .unreadable(let f, let why):
            "\(f) can't be installed: \(why)"
        }
    }
}

/// Downloads and checks packages (FirmwareInstaller uses it).
public struct FirmwarePackages: Sendable {
    public let directory: URL
    let fetcher: any InstallerFetching

    public init(directory: URL = RemoteFM1Releases.defaultCache.appendingPathComponent("packages"),
                fetcher: any InstallerFetching = URLSessionFetcher()) {
        self.directory = directory
        self.fetcher = fetcher
    }

    /// the package, from the cache if a checked copy is there, else downloaded; checked either way
    public func fetch(_ ref: FirmwarePackageRef) async throws -> VerifiedPackage {
        let file = directory.appendingPathComponent(ref.file)
        if let data = try? Data(contentsOf: file), let ok = try? Self.verify(data, ref) {
            return ok
        }
        let data = try await fetcher.data(from: RemoteFM1Releases.packageURL(ref.file))
        let ok = try Self.verify(data, ref)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return ok
    }

    /// the checks, in order: SHA-256 (before FM1Kit reads a byte of it), FM1Kit's package checks, the identity
    public static func verify(_ data: Data, _ ref: FirmwarePackageRef) throws -> VerifiedPackage {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sha == ref.sha256 else {
            throw PackageProblem.checksumMismatch(file: ref.file, expected: ref.sha256, got: sha)
        }
        let pkg: FwscPackage
        do {
            pkg = try FwscPackage(data: data)
        } catch {
            throw PackageProblem.unreadable(file: ref.file, why: error.errorDescription ?? "\(error)")
        }
        guard pkg.isFirmware else {
            throw PackageProblem.unreadable(file: ref.file, why: "it holds no firmware.")
        }
        guard pkg.product == ref.identity else {
            throw PackageProblem.identityMismatch(file: ref.file, expected: ref.identity, got: pkg.product)
        }
        return VerifiedPackage(ref: ref, package: pkg)
    }
}
