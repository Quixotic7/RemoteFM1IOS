// RFMBenchEmu: runs fm1bench (fm1-emu's interpreter, bench/src/lib.rs) on the packages bundled under fwsc/ at
// launch, on a background thread at user-interactive QoS; writes Documents/results.txt and shows it.
// Launch argument "quick": one short run per package (a smoke test).
import SwiftUI
import UIKit

final class Log: ObservableObject {
    static let shared = Log()
    @Published var text = ""
    private let lock = NSLock()
    private var buf = ""
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.txt")

    func add(_ s: String) {
        lock.lock()
        buf += s
        let all = buf
        lock.unlock()
        try? all.write(to: url, atomically: true, encoding: .utf8)
        print(s, terminator: "")
        DispatchQueue.main.async { self.text = all }
    }
}

private let logLine: @convention(c) (UnsafePointer<CChar>?) -> Void = { p in
    guard let p else { return }
    Log.shared.add(String(cString: p))
}

func runBench() {
    let args = ProcessInfo.processInfo.arguments
    let quick = args.contains("quick")
    // mhz=N: the emulated clock (default 240); only=a,b: those packages (by file stem); split=0: no split run
    let mhz = args.compactMap { $0.hasPrefix("mhz=") ? UInt32($0.dropFirst(4)) : nil }.first ?? 240
    let only = args.first { $0.hasPrefix("only=") }.map { Set($0.dropFirst(5).split(separator: ",").map(String.init)) }
    let splitOn = !args.contains("split=0")
    var (runs, settle, idle, chord): (UInt32, UInt32, UInt32, UInt32) = quick ? (1, 3000, 1000, 1000) : (3, 3000, 10000, 10000)
    // runs=N: fewer (or more) runs per package
    if let n = args.compactMap({ $0.hasPrefix("runs=") ? UInt32($0.dropFirst(5)) : nil }).first { runs = n }
    let d = UIDevice.current
    var u = utsname()
    uname(&u)
    let model = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    let pi = ProcessInfo.processInfo
    Log.shared.add("RFMBenchEmu \(Date()) \(model) iOS \(d.systemVersion), \(pi.activeProcessorCount) cores, thermal \(pi.thermalState.rawValue), low power \(pi.isLowPowerModeEnabled), JIT compiled in: \(fm1b_jit_compiled()), \(quick ? "quick" : "full"), \(mhz) MHz, args \(args.dropFirst())\n")
    let dir = Bundle.main.bundleURL.appendingPathComponent("fwsc")
    // (name, file, split timing run as well)
    let pkgs: [(String, String, Bool)] = [
        ("felucca-1.6.1", "felucca.fwsc", false),
        ("v15", "v15.fwsc", true),
        ("choralroot-0.25.1", "choralroot.fwsc", false),
        ("choralroot-0.27-1core", "cr027-1core.fwsc", false),
    ]
    let cap = 1 << 16
    var out = [UInt8](repeating: 0, count: cap)
    for (name, file, split) in pkgs where only == nil || only!.contains(String(file.dropLast(5))) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else {
            Log.shared.add("\(name): \(file) not in the bundle\n")
            continue
        }
        let bytes = [UInt8](data)
        for s in split && splitOn ? [Int32(0), 1] : [0] {
            _ = bytes.withUnsafeBufferPointer { b in
                fm1b_bench(b.baseAddress, b.count, name, mhz, 0, s == 1 ? 1 : runs, s, settle, idle, chord, &out, cap, logLine)
            }
        }
        Log.shared.add("thermal \(pi.thermalState.rawValue)\n")
    }
    Log.shared.add("DONE \(Date())\n")
    // "exit": end the process (devicectl --console then returns); results.txt is written already
    if args.contains("exit") { exit(0) }
}

@main
struct BenchApp: App {
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        let t = Thread { runBench() }
        t.qualityOfService = .userInteractive
        t.stackSize = 8 << 20
        t.start()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @ObservedObject var log = Log.shared
    var body: some View {
        ScrollView {
            Text(log.text.isEmpty ? "starting…" : log.text)
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}
