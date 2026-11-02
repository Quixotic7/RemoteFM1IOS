// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The folder a document picker last picked from (the cartridge page's .syx picker, Add firmware…, a web editor's Add files…, Restore), so the next one opens
// there: a bookmark of the picked file's parent folder (its URL alone when the folder can't be bookmarked), in
// UserDefaults by key. A folder since gone: the picker opens where the system likes.

import Foundation

public struct PickerFolder: @unchecked Sendable {
    public let key: String
    let defaults: UserDefaults

    public static let cart = PickerFolder(key: "picker.folder.cart")
    public static let firmware = PickerFolder(key: "picker.folder.firmware")
    public static let editor = PickerFolder(key: "picker.folder.editor")      // (a firmware's web editor's file inputs)
    public static let restore = PickerFolder(key: "picker.folder.restore")    // (States: restore, a transfer)

    public init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    /// remembers the folder of `picked` (call while the picked file is still reachable)
    public func remember(_ picked: [URL]) {
        guard let file = picked.first, file.isFileURL else { return }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let dir = file.deletingLastPathComponent()
        if let b = try? dir.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(b, forKey: key + ".bookmark")
        } else {
            defaults.removeObject(forKey: key + ".bookmark")
        }
        defaults.set(dir.absoluteString, forKey: key + ".url")
    }

    /// the folder to open in, if it is still there
    public var url: URL? {
        var u: URL?
        if let b = defaults.data(forKey: key + ".bookmark") {
            var stale = false
            u = try? URL(resolvingBookmarkData: b, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if u == nil, let s = defaults.string(forKey: key + ".url") { u = URL(string: s) }
        guard let u, u.isFileURL else { return nil }
        // (not checked for existence: the app could read only the picked file, never its folder, so a folder outside
        // the app always looked missing and every picker opened in RemoteFM1. The picker copes with a folder gone)
        return u
    }
}
