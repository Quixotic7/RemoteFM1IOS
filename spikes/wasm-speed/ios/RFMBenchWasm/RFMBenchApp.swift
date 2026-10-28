// SPDX-License-Identifier: GPL-3.0-only
// The bench on the iPhone (../../README.md): runs rfmbench_run at launch on a background thread (user-interactive
// QoS, 8 MB stack), shows the report as it grows, writes it to Documents/results.txt and prints it to stdout.
// Launch arguments: words with '=' are the bench's spec ("engines=native,wasm3 runs=1"); none: the default.
import SwiftUI
import UIKit

final class BenchModel: ObservableObject {
    @Published var text = ""
    private var started = false
    static var shared: BenchModel?

    func start() {
        guard !started else { return }
        started = true
        BenchModel.shared = self
        UIApplication.shared.isIdleTimerDisabled = true
        let spec = CommandLine.arguments.dropFirst().filter { $0.contains("=") }.joined(separator: " ")
        let dir = Bundle.main.resourcePath ?? "."
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent("results.txt")
        try? "running\n".write(to: out, atomically: true, encoding: .utf8)
        let thermal = { () -> String in
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "?"
            }
        }
        let t = Thread {
            let head = "device: \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion), thermal \(thermal()), "
                + "low power \(ProcessInfo.processInfo.isLowPowerModeEnabled), spec '\(spec)'"
            BenchModel.emit(head)
            let r = spec.isEmpty ? rfmbench_run(dir, nil, benchLine) : rfmbench_run(dir, spec, benchLine)
            var report = head + "\n"
            if let r = r {
                report += String(cString: r)
                free(r)
            }
            report += "thermal at the end: \(thermal())\nDONE\n"
            try? report.write(to: out, atomically: true, encoding: .utf8)
            BenchModel.emit("DONE (Documents/results.txt)")
        }
        t.qualityOfService = .userInteractive
        t.stackSize = 8 << 20
        t.start()
    }

    static func emit(_ s: String) {
        print(s)
        fflush(stdout)
        DispatchQueue.main.async { shared?.text += s + "\n" }
    }
}

// the bench's progress callback (a C function pointer: no captures)
private func benchLine(_ line: UnsafePointer<CChar>?) {
    guard let line = line else { return }
    BenchModel.emit(String(cString: line))
}

@main
struct RFMBenchApp: App {
    @StateObject private var model = BenchModel()
    var body: some Scene {
        WindowGroup {
            ScrollView([.vertical, .horizontal]) {
                Text(model.text.isEmpty ? "starting" : model.text)
                    .font(.system(size: 8, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .onAppear { model.start() }
        }
    }
}
