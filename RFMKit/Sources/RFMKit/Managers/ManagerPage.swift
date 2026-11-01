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
                Text("\(firmware) manager").font(RFMFonts.ui(17, 700)).foregroundStyle(Palette.sheetText)
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
        c.userContentController.addUserScript(WKUserScript(source: Self.playerScript.replacingOccurrences(of: "%STATE%", with: json),
                                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        c.userContentController.add(WeakHandler(context.coordinator), name: "fm1mgr")
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false
        w.backgroundColor = .black
        context.coordinator.attach(w)
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    static func dismantleUIView(_ w: WKWebView, coordinator: Bridge) {
        w.configuration.userContentController.removeScriptMessageHandler(forName: "fm1mgr")
        coordinator.detach()
    }

    /// the player's side of fm1-shim.js's protocol (web/managers/fm1-shim.js): hello -> state; midi both ways; bye
    static let playerScript = """
    (function () {
      "use strict";
      const CH = "remotefm1-managers", pid = "app-" + Math.random().toString(36).slice(2, 10), state = %STATE%;
      const bc = new BroadcastChannel(CH);
      const send = (m) => bc.postMessage(Object.assign({ __fm1mgr: 1, from: "player", pid }, m));
      bc.onmessage = (e) => {
        const m = e.data;
        if (!m || m.__fm1mgr !== 1 || m.from === "player") return;
        if (m.type === "hello") send({ type: "state", sid: m.sid, connected: true, port: state.port, firmware: state.firmware, engine: "native" });
        else if (m.type === "midi" && m.bytes) window.webkit.messageHandlers.fm1mgr.postMessage(Array.from(m.bytes));
      };
      window.__fm1player = { midi(list) { for (const b of list) send({ type: "midi", sid: "*", bytes: Uint8Array.from(b) }); } };
      window.addEventListener("pagehide", () => send({ type: "bye", sid: "*" }));
    })();
    """

    @MainActor final class Bridge: NSObject, WKScriptMessageHandler {
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
            guard let a = message.body as? [Any] else { return }
            let bytes = a.compactMap { ($0 as? NSNumber)?.intValue }.filter { (0...255).contains($0) }.map { UInt8($0) }
            Task { @MainActor in self.enqueue(bytes) }
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
