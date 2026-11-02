// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The launch notice (the owner, 2026-11-02: testers kept sending feedback from old builds): at the standalone app's
// launch, one dismissible message when a newer app build is out (release/ios.json in this repository, read from
// GitHub; TestFlight tells an app nothing) or firmware here has an update (Get firmware's own list). Closed, it stays
// closed until something newer comes out (the dismissed set is remembered).

import Foundation

/// release/ios.json
public struct LatestBuild: Decodable, Equatable, Sendable {
    public var build: Int
    public var version: String?
    public var url: String?
}

public struct UpdateNotice: Equatable, Sendable {
    public var newBuild: Int?                  // a newer app build (nil: this one is the newest)
    public var url: URL?                       // where to get it (TestFlight's public link)
    public var firmware: [String]              // firmware here with an update, by name
    public var signature: String               // what it tells, for "already closed"

    public static let latestURL = URL(string: "https://raw.githubusercontent.com/Quixotic7/RemoteFM1IOS/main/release/ios.json")!
    static let dismissedKey = "updateNotice.dismissed"

    /// what to tell, nil: nothing new. updates: Get firmware's entries in the Update state (name, its version)
    public static func make(build: Int, latest: LatestBuild?, updates: [(name: String, version: String)]) -> UpdateNotice? {
        let nb = latest.flatMap { $0.build > build ? $0.build : nil }
        let fw = updates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard nb != nil || !fw.isEmpty else { return nil }
        let sig = "b\(nb ?? 0)|" + fw.map { "\($0.name) \($0.version)" }.joined(separator: ",")
        return UpdateNotice(newBuild: nb, url: latest?.url.flatMap(URL.init(string:)), firmware: fw.map(\.name), signature: sig)
    }

    public var title: String { newBuild != nil ? "A new RemoteFM1 is out" : "Firmware updates" }

    public func message(current: Int) -> String {
        var s: [String] = []
        if let b = newBuild {
            s.append("Build \(b) is on TestFlight; you have build \(current). Please update before sending feedback.")
        }
        if !firmware.isEmpty {
            let names = firmware.count > 3 ? Array(firmware.prefix(3)) + ["\(firmware.count - 3) more"] : firmware
            let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]
            s.append("\(firmware.count == 1 ? "An update" : "Updates") for \(list) in Get firmware.")
        }
        return s.joined(separator: "\n\n")
    }

    /// whether it was closed before (the same builds and versions)
    public func dismissed(_ d: UserDefaults = .standard) -> Bool { d.string(forKey: Self.dismissedKey) == signature }
    public func dismiss(_ d: UserDefaults = .standard) { d.set(signature, forKey: Self.dismissedKey) }

    /// release/ios.json, nil: not reachable (offline: no notice about the app)
    public static func latest(timeout: TimeInterval = 6) async -> LatestBuild? {
        var r = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(LatestBuild.self, from: d)
    }
}
