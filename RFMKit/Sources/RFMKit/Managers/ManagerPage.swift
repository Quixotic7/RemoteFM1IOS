// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The firmware's own web manager in the app (PLAN.md section 18 step 5): remotefm1.com's hosted page in a WKWebView,
// with "the player" injected at document start. The page's fm1-shim.js (top level, so on its BroadcastChannel) says
// hello; the player answers with the port (the firmware's USB name) and passes MIDI: the page's to the running
// firmware (CorePlayer.managerSend), the firmware's back to the page (managerTake, every 10 ms). Opening it keeps a
// safety copy first ("before manager write"): a manager may write a whole bank. The app only (not the AU).

#if os(iOS)
import SwiftUI
import WebKit
import UniformTypeIdentifiers

public struct ManagerPage: View {
    let player: CorePlayer
    let url: URL
    let port: String
    let firmware: String
    let done: () -> Void

    public init(player: CorePlayer, url: URL, port: String, firmware: String, done: @escaping () -> Void) {
        self.player = player
        self.url = url
        self.port = port
        self.firmware = firmware
        self.done = done
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(firmware) editor").font(RFMFonts.ui(17, 700)).foregroundStyle(Palette.sheetText)
                Spacer()
                SheetButton("Done", accent: true, action: done)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Palette.sheetBackground)
            ManagerWebView(player: player, url: url, port: port, firmware: firmware)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Palette.sheetBackground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

struct ManagerWebView: UIViewRepresentable {
    let player: CorePlayer
    let url: URL
    let port: String
    let firmware: String

    func makeCoordinator() -> Bridge { Bridge(player: player) }

    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        let state = ["port": port, "firmware": firmware]
        let json = (try? JSONSerialization.data(withJSONObject: state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        c.userContentController.addUserScript(WKUserScript(source: Self.webMIDI.replacingOccurrences(of: "%STATE%", with: json),
                                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        c.userContentController.add(WeakHandler(context.coordinator), name: "fm1mgr")
        c.userContentController.add(WeakHandler(context.coordinator), name: "fm1pick")
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false
        w.backgroundColor = .black
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        context.coordinator.attach(w)

        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    static func dismantleUIView(_ w: WKWebView, coordinator: Bridge) {
        w.configuration.userContentController.removeScriptMessageHandler(forName: "fm1mgr")
        w.configuration.userContentController.removeScriptMessageHandler(forName: "fm1pick")
        coordinator.detach()
    }

    /// a whole Web MIDI for the page (after RemoteFM1's web/managers/fm1-shim.js, which the site's hosted pages load:
    /// set as window.__fm1shim first so that one stands aside): one input and one output named as the firmware's USB
    /// port, always connected, sysex granted; what the page sends goes to the app (fm1mgr), the app's
    /// __fm1player.midi(list) comes in on the input. Any editor page works, the site's copies and the authors' own
    static let webMIDI = """
    (function (G) {
      "use strict";
      if (G.__fm1app) return;
      const state = %STATE%, NAME = state.port || "FM-1";
      const post = (bytes) => { try { G.webkit.messageHandlers.fm1mgr.postMessage(Array.from(bytes)); } catch (_) {} };
      const msgEvent = (data) => { try { return new MessageEvent("midimessage", { data }); } catch (_) {
        const e = new Event("midimessage"); Object.defineProperty(e, "data", { value: data }); return e; } };
      const connEvent = (port) => { const e = new Event("statechange"); Object.defineProperty(e, "port", { value: port }); return e; };
      class Port extends EventTarget {
        constructor(type, id) { super(); this._type = type; this._id = id; this._conn = "closed"; this._onstate = null;
          this.addEventListener("statechange", (e) => { if (typeof this._onstate === "function") this._onstate.call(this, e); }); }
        get id() { return this._id; } get name() { return NAME; } get manufacturer() { return "RemoteFM1"; }
        get version() { return ""; } get type() { return this._type; } get state() { return "connected"; }
        get connection() { return this._conn; }
        get onstatechange() { return this._onstate; } set onstatechange(f) { this._onstate = f; }
        open() { if (this._conn !== "open") { this._conn = "open"; changed(this); } return Promise.resolve(this); }
        close() { if (this._conn !== "closed") { this._conn = "closed"; changed(this); } return Promise.resolve(this); }
      }
      class Input extends Port {
        constructor() { super("input", "remotefm1-in"); this._onmsg = null;
          super.addEventListener("midimessage", (e) => { if (typeof this._onmsg === "function") this._onmsg.call(this, e); }); }
        get onmidimessage() { return this._onmsg; } set onmidimessage(f) { this._onmsg = f; if (f) this.open(); }
        addEventListener(t, f, o) { super.addEventListener(t, f, o); if (t === "midimessage") this.open(); }
      }
      class Output extends Port {
        constructor() { super("output", "remotefm1-out"); }
        send(data, ts) {
          const bytes = Uint8Array.from(data || [], (v) => { if (!Number.isInteger(v) || v < 0 || v > 255) throw new TypeError("MIDIOutput.send: bytes 0..255"); return v; });
          if (!bytes.length) return; if (this._conn !== "open") this.open();
          const delay = typeof ts === "number" && ts > 0 ? ts - performance.now() : 0;
          if (delay > 1) setTimeout(() => post(bytes), delay); else post(bytes);
        }
        clear() {}
      }
      const input = new Input(), output = new Output(), accesses = new Set();
      const inputs = new Map([[input.id, input]]), outputs = new Map([[output.id, output]]);
      class Access extends EventTarget {
        constructor() { super(); this._onstate = null;
          this.addEventListener("statechange", (e) => { if (typeof this._onstate === "function") this._onstate.call(this, e); }); }
        get inputs() { return inputs; } get outputs() { return outputs; } get sysexEnabled() { return true; }
        get onstatechange() { return this._onstate; } set onstatechange(f) { this._onstate = f; }
      }
      function changed(port) { port.dispatchEvent(connEvent(port)); for (const a of accesses) a.dispatchEvent(connEvent(port)); }
      function requestMIDIAccess() { const a = new Access(); accesses.add(a); return Promise.resolve(a); }
      Object.defineProperty(G.navigator, "requestMIDIAccess", { value: requestMIDIAccess, configurable: true, writable: true });
      // (pages that ask first: midi and midi-with-sysex are granted)
      if (G.navigator.permissions && G.navigator.permissions.query) {
        const q = G.navigator.permissions.query.bind(G.navigator.permissions);
        G.navigator.permissions.query = (d) => (d && d.name === "midi") ? Promise.resolve({ state: "granted", onchange: null }) : q(d);
      }
      // (file inputs: the app's own picker, which opens in the folder last picked from and takes any file. iOS's
      // picker for web pages always opens in RemoteFM1's folder and greys out files whose extension it has no type
      // for, Digitone's .dnsnd, .dn2pst and .dn2snd among them, even when the page accepts them)
      const picks = new Map(); let pickN = 0;
      const canPick = () => { try { return !!G.webkit.messageHandlers.fm1pick; } catch (_) { return false; } };
      const openPicker = (el) => { const id = ++pickN; picks.set(id, el);
        G.webkit.messageHandlers.fm1pick.postMessage({ id, multiple: !!el.multiple }); };
      const clickFile = HTMLInputElement.prototype.click;
      HTMLInputElement.prototype.click = function () {
        if (this.type === "file" && canPick()) { if (!this.disabled) openPicker(this); return; }
        return clickFile.apply(this, arguments);
      };
      if (HTMLInputElement.prototype.showPicker) {
        const show = HTMLInputElement.prototype.showPicker;
        HTMLInputElement.prototype.showPicker = function () {
          if (this.type === "file" && canPick()) { if (!this.disabled) openPicker(this); return; }
          return show.apply(this, arguments);
        };
      }
      G.addEventListener("click", (e) => {
        const t = e.target; if (!t || !canPick()) return;
        const lab = t.closest ? t.closest("label") : null;
        const el = (t.tagName === "INPUT" && t.type === "file") ? t : (lab && lab.control && lab.control.type === "file" ? lab.control : null);
        if (!el || el.disabled) return;
        e.preventDefault(); e.stopPropagation(); openPicker(el);
      }, true);
      G.__fm1pick = (id, files) => {
        const el = picks.get(id); picks.delete(id); if (!el) return;
        if (!files || !files.length) { el.dispatchEvent(new Event("cancel", { bubbles: true })); return; }
        const dt = new DataTransfer();
        for (const f of files) { const bin = atob(f.b64), u = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
          dt.items.add(new File([u], f.name, { type: f.type || "", lastModified: f.modified || Date.now() })); }
        el.files = dt.files;
        el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true }));
      };
      G.__fm1player = { midi(list) { if (input._conn !== "open") return; for (const b of list) input.dispatchEvent(msgEvent(Uint8Array.from(b))); } };
      G.__fm1app = true;
      G.__fm1shim = { app: true, manager: state.firmware, framed: false };   // (the site's fm1-shim.js: stand aside)
    })(window);
    """

    @MainActor final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                               UIDocumentPickerDelegate {
        let player: CorePlayer
        private weak var web: WKWebView?
        private var poll: Task<Void, Never>?

        init(player: CorePlayer) { self.player = player }

        func attach(_ w: WKWebView) {
            web = w
            Task { await player.safetyCopy(.beforeManagerWrite) }
            player.managerAttach(true)
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    self?.deliver()
                }
            }
        }

        func detach() {
            poll?.cancel()
            poll = nil
            player.managerAttach(false)
        }

        private func deliver() {
            let msgs = player.managerTake()
            guard !msgs.isEmpty, let web,
                  let d = try? JSONSerialization.data(withJSONObject: msgs.map { $0.map(Int.init) }),
                  let js = String(data: d, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.__fm1player && window.__fm1player.midi(\(js))")
        }

        nonisolated func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "fm1pick" {
                guard let d = message.body as? [String: Any], let id = (d["id"] as? NSNumber)?.intValue else { return }
                let multiple = (d["multiple"] as? NSNumber)?.boolValue ?? false
                Task { @MainActor in self.pick(id, multiple: multiple) }
                return
            }
            guard let a = message.body as? [Any] else { return }
            let bytes = a.compactMap { ($0 as? NSNumber)?.intValue }.filter { (0...255).contains($0) }.map { UInt8($0) }
            Task { @MainActor in self.enqueue(bytes) }
        }

        // MARK: the page's alert, confirm and prompt (without these WKWebView answers at once: confirm() false, so
        // the editor's "Place all 128 sounds?" was a Cancel and nothing was placed)

        private func present(_ a: UIAlertController) -> Bool {
            guard let w = web, var top = w.window?.rootViewController else { return false }
            while let p = top.presentedViewController { top = p }
            top.present(a, animated: true)
            return true
        }

        func webView(_: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame _: WKFrameInfo) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default) { _ in c.resume() })
                if !present(a) { c.resume() }
            }
        }

        func webView(_: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame _: WKFrameInfo) async -> Bool {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in c.resume(returning: false) })
                a.addAction(UIAlertAction(title: "OK", style: .default) { _ in c.resume(returning: true) })
                if !present(a) { c.resume(returning: false) }
            }
        }

        func webView(_: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame _: WKFrameInfo) async -> String? {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
                a.addTextField { $0.text = defaultText }
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in c.resume(returning: nil) })
                a.addAction(UIAlertAction(title: "OK", style: .default) { [weak a] _ in
                    c.resume(returning: a?.textFields?.first?.text ?? "")
                })
                if !present(a) { c.resume(returning: nil) }
            }
        }

        // MARK: the page's file inputs (the app's picker: the last folder, any file)

        private var picking: [ObjectIdentifier: Int] = [:]
        static let maxPickBytes = 64 << 20

        private func pick(_ id: Int, multiple: Bool) {
            guard let w = web, var top = w.window?.rootViewController else { return answer(id, []) }
            while let p = top.presentedViewController { top = p }
            let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
            p.allowsMultipleSelection = multiple
            p.directoryURL = PickerFolder.editor.url
            p.delegate = self
            picking[ObjectIdentifier(p)] = id
            top.present(p, animated: true)
        }

        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let id = picking.removeValue(forKey: ObjectIdentifier(c)) else { return }
            PickerFolder.editor.remember(urls)
            var files: [[String: Any]] = [], total = 0
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: u), total + d.count <= Self.maxPickBytes else { continue }
                total += d.count
                let modified = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                files.append(["name": u.lastPathComponent, "b64": d.base64EncodedString(),
                              "modified": Int((modified ?? Date()).timeIntervalSince1970 * 1000)])
            }
            answer(id, files)
        }

        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {
            if let id = picking.removeValue(forKey: ObjectIdentifier(c)) { answer(id, []) }
        }

        private func answer(_ id: Int, _ files: [[String: Any]]) {
            guard let web, let d = try? JSONSerialization.data(withJSONObject: files),
                  let js = String(data: d, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.__fm1pick && window.__fm1pick(\(id), \(js))")
        }

        // MARK: downloads (an editor's backups, presets) and new windows

        func webView(_: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
            a.shouldPerformDownload ? .download : .allow
        }

        func webView(_: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            r.canShowMIMEType ? .allow : .download
        }

        func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
        func webView(_: WKWebView, navigationResponse _: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

        private var saving: [ObjectIdentifier: URL] = [:]

        func download(_ d: WKDownload, decideDestinationUsing _: URLResponse, suggestedFilename name: String) async -> URL? {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name.isEmpty ? "download" : name)
            saving[ObjectIdentifier(d)] = url
            return url
        }

        func downloadDidFinish(_ d: WKDownload) {
            guard let url = saving.removeValue(forKey: ObjectIdentifier(d)) else { return }
            share(url)
        }

        func download(_ d: WKDownload, didFailWithError _: Error, resumeData _: Data?) { saving[ObjectIdentifier(d)] = nil }

        /// the file the editor saved: the share sheet (Save to Files, AirDrop, ...)
        private func share(_ url: URL) {
            guard let w = web, var top = w.window?.rootViewController else { return }
            while let p = top.presentedViewController { top = p }
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = w
            vc.popoverPresentationController?.sourceRect = CGRect(x: w.bounds.midX, y: w.bounds.midY, width: 1, height: 1)
            top.present(vc, animated: true)
        }

        /// a link to a new window: in Safari (the editor's own site, its docs)
        func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration, for a: WKNavigationAction,
                     windowFeatures _: WKWindowFeatures) -> WKWebView? {
            if let u = a.request.url, u.scheme == "https" || u.scheme == "http" { UIApplication.shared.open(u) }
            return nil
        }

        // (in the page's order: a SysEx waiting for room must not be overtaken)
        private var queue: [[UInt8]] = []
        private var sending = false

        private func enqueue(_ bytes: [UInt8]) {
            queue.append(bytes)
            guard !sending else { return }
            sending = true
            Task { @MainActor in
                while !self.queue.isEmpty {
                    let m = self.queue.removeFirst()
                    _ = await self.player.managerSend(m)
                }
                self.sending = false
            }
        }
    }

    /// WKUserContentController keeps its handlers strongly: this breaks the cycle
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Bridge?
        init(_ t: Bridge) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }
}
#endif
