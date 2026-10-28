//! fm1bench [--mhz 240] [--jit] [--runs 3] [--split] [--routes] [--settle MS] [--idle MS] [--chord MS]
//!          NAME=PATH.fwsc ...
use fm1bench::{bench, Opts};

/// macOS runs default-QoS threads on the efficiency cores: ask for a performance core (as fm1-live).
fn high_priority() {
    extern "C" {
        fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: i32) -> i32;
    }
    const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
    unsafe {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

fn main() {
    high_priority();
    let mut o = Opts::default();
    let mut runs = 3;
    let mut pkgs = Vec::new();
    let mut guest = 0u32;
    let a: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < a.len() {
        let v = |i: usize| a.get(i + 1).and_then(|s| s.parse::<u64>().ok()).expect("number");
        match a[i].as_str() {
            "--mhz" => { o.mhz = v(i); i += 1 }
            "--runs" => { runs = v(i) as usize; i += 1 }
            "--settle" => { o.settle_ms = v(i); i += 1 }
            "--idle" => { o.idle_ms = v(i); i += 1 }
            "--chord" => { o.chord_ms = v(i); i += 1 }
            "--jit" => o.jit = true,
            "--split" => o.split = true,
            "--routes" => o.routes = true,
            "--guest" => { guest = v(i) as u32; i += 1 }
            s => {
                let (n, p) = s.split_once('=').expect("NAME=PATH");
                pkgs.push((n.to_owned(), std::fs::read(p).expect("read package")));
            }
        }
        i += 1;
    }
    for (n, p) in &pkgs {
        if guest > 0 {
            println!("== {n}");
            print!("{}", fm1bench::guest_profile(p, &o, guest).unwrap_or_else(|e| e));
            continue;
        }
        let _ = bench(n, p, &o, runs, &mut |s| print!("{s}"));
    }
}
