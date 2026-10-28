//! fm1bench: how fast does fm1-emu (joakimeriksson/fm1-emu, MIT, 5fbb066) run a real FM-1
//! firmware package (.fwsc)? Boot, settle, then idle and a held C major chord, timed in device
//! seconds per wall second. A C entry point (`fm1b_bench`) for the iOS bench app, and an rlib for
//! the Mac CLI (src/main.rs).
//!
//! The machine is driven as fm1-emu's own hosts drive it (crates/fm1-plugin/src/engine.rs,
//! crates/fm1-web/src/lib.rs): `stock_from_package`, `stock_boot`, cpu0 in user mode, skip_idle on,
//! `machine::run_dual` + `machine::run_blocks` in chunks of 20 000 cpu0 instructions (the plugin's
//! chunk), the audio taken out of `soc.periph.audio` after each chunk, keys as `Action::Key`.

use fm1_core::{Bus, Cpu};
use fm1_soc::{machine, Action, Soc};
use std::time::Instant;

const RAM_BASE: u32 = 0x01c0_0000;
const RAM_SIZE: usize = 1 << 20;
/// cpu0 instructions per run call (fm1-plugin's engine: `mm.run(20_000)`)
const CHUNK: u32 = 20_000;
/// C4, E4, G4: key ids 14 + semitones above F3 (fm1_soc::periph::key_id)
pub const CHORD: [u8; 3] = [21, 25, 28];

/// Is fm1-core's AArch64 JIT compiled into this build at all? (fm1-core gates it on
/// `target_arch = "aarch64", target_os = "macos"`; an iOS build has no JIT code and no MAP_JIT.)
pub const JIT_COMPILED: bool = cfg!(all(target_arch = "aarch64", target_os = "macos"));

#[derive(Clone, Debug)]
pub struct Opts {
    pub mhz: u64,
    pub jit: bool,
    pub settle_ms: u64,
    pub idle_ms: u64,
    pub chord_ms: u64,
    /// time cpu0 and cpu1 separately (a copy of run_dual with two clocks; slightly slower)
    pub split: bool,
    /// fm1-core's route counters (slow path share); allocates, slows the run
    pub routes: bool,
}

impl Default for Opts {
    fn default() -> Self {
        Opts { mhz: 240, jit: false, settle_ms: 3000, idle_ms: 10_000, chord_ms: 10_000, split: false, routes: false }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Phase {
    pub wall: f64,
    pub dev_ms: u64,
    pub insn0: u64,
    pub insn1: u64,
    pub cycles: u64,
    pub skipped: u64,
    pub frames: u64,
    pub sumsq: f64,
    pub peak: i32,
    pub lcd_frames: u64,
    /// wall seconds inside cpu0's run_blocks / cpu1's run_cpu1 (split runs only)
    pub t0: f64,
    pub t1: f64,
}

impl Phase {
    pub fn xrt(&self) -> f64 {
        self.dev_ms as f64 / 1000.0 / self.wall.max(1e-9)
    }
    pub fn rms(&self) -> f64 {
        if self.frames == 0 { 0.0 } else { (self.sumsq / (2 * self.frames) as f64).sqrt() }
    }
    pub fn rms_dbfs(&self) -> f64 {
        let r = self.rms();
        if r <= 0.0 { f64::NEG_INFINITY } else { 20.0 * (r / 32768.0).log10() }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Run {
    pub boot_wall: f64,
    pub settle: Phase,
    pub idle: Phase,
    pub chord: Phase,
    pub lcd_lit: usize,
    pub lcd_colors: usize,
    pub audio_hash: u64,
    pub lcd_hash: u64,
    pub halted: Option<String>,
    pub cpu1_at_ms: Option<u64>,
    pub identity: String,
    pub slow_share: Option<f64>,
    pub pc0: u32,
}

struct Machine {
    cpu: Cpu,
    cpu1: Option<Cpu>,
    soc: Soc,
    pending_tick: bool,
    halted: Option<String>,
    jit: bool,
    split: bool,
    t0: f64,
    t1: f64,
    /// every sample taken (the hash covers a fixed prefix: a run may stop a DMA half later or earlier)
    audio_all: Vec<i16>,
}

fn fnv(mut h: u64, bytes: &[u8]) -> u64 {
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x100_0000_01b3);
    }
    h
}
const FNV0: u64 = 0xcbf2_9ce4_8422_2325;

impl Machine {
    /// fm1-plugin's Machine::boot (engine.rs), with the clock and the JIT as parameters.
    fn boot(pkg: &[u8], o: &Opts) -> Result<(Self, String), String> {
        let st = std::panic::catch_unwind(|| fm1_soc::stock_from_package(pkg, None))
            .map_err(|_| "malformed firmware package".to_owned())??;
        let mut soc = Soc::new(RAM_SIZE, st.xip);
        soc.periph.hz = o.mhz * 1_000_000;
        soc.periph.skip_idle = true;
        let mut cpu = Cpu::new(st.entry);
        cpu.jit_on = o.jit && JIT_COMPILED;
        cpu.user = true;
        cpu.profile = o.routes;
        let params = RAM_BASE + 0x7fc00;
        soc.write32(params, params + 0x40);
        cpu.regs[0] = fm1_soc::stock_boot(&mut soc, &st.flash, params, st.board);
        if soc.board != fm1_soc::Board::Fm1 {
            return Err(format!("not an FM-1 package ({})", st.identity));
        }
        let jit = cpu.jit_on;
        Ok((Machine { cpu, cpu1: None, soc, pending_tick: false, halted: None, jit, split: o.split, t0: 0.0, t1: 0.0, audio_all: Vec::new() }, st.identity))
    }

    fn run(&mut self, n: u32) {
        let r = if self.split {
            self.run_dual_timed(n)
        } else {
            let Machine { cpu, cpu1, soc, pending_tick, jit, .. } = self;
            machine::run_dual(cpu1, soc, n, RAM_SIZE, *jit, |soc, k| machine::run_blocks(cpu, soc, k, pending_tick))
        };
        if let Err(e) = r {
            self.halted = Some(e);
        }
        if let Some(c1) = self.cpu1.as_mut() {
            c1.profile = self.cpu.profile;
        }
    }

    /// fm1_soc::machine::run_dual, line for line, with a clock around each core's part.
    fn run_dual_timed(&mut self, n: u32) -> Result<(), String> {
        let Machine { cpu, cpu1, soc, pending_tick, jit, t0, t1, .. } = self;
        let mut done = 0;
        while cpu1.is_none() {
            *cpu1 = machine::released_cpu1(soc, RAM_SIZE).map(|mut c| {
                c.jit_on = *jit;
                c
            });
            if cpu1.is_some() || done >= n {
                break;
            }
            let k = (n - done).min(4096);
            soc.periph.room_cap = k as u64;
            let a = Instant::now();
            machine::run_blocks(cpu, soc, k, pending_tick)?;
            *t0 += a.elapsed().as_secs_f64();
            done += k;
        }
        let Some(c1) = cpu1.as_mut() else { return Ok(()) };
        soc.periph.room_cap = machine::SLICE as u64;
        while done < n {
            let k = (n - done).min(machine::SLICE);
            let c0 = soc.periph.cycles;
            let a = Instant::now();
            if soc.core_paused(0) {
                soc.advance(k as u64);
            } else {
                machine::run_blocks(cpu, soc, k, pending_tick)?;
            }
            let b = Instant::now();
            done += k;
            let dt = soc.periph.cycles - c0;
            machine::run_cpu1(c1, soc, dt)?;
            let c = Instant::now();
            *t0 += (b - a).as_secs_f64();
            *t1 += (c - b).as_secs_f64();
        }
        Ok(())
    }

    fn phase(&mut self, end_ms: u64) -> Phase {
        let mut p = Phase::default();
        let (i0, i1) = (self.cpu.insn_count, self.cpu1.as_ref().map_or(0, |c| c.insn_count));
        let (cy, sk, ms0, lf) = (self.soc.periph.cycles, self.soc.periph.skipped, self.soc.periph.ms(), self.soc.lcd.frames);
        let (tt0, tt1) = (self.t0, self.t1);
        let start = Instant::now();
        while self.soc.periph.ms() < end_ms && self.halted.is_none() {
            self.run(CHUNK);
            let a = std::mem::take(&mut self.soc.periph.audio);
            for &s in &a {
                p.sumsq += (s as f64) * (s as f64);
                p.peak = p.peak.max((s as i32).abs());
            }
            p.frames += (a.len() / 2) as u64;
            self.audio_all.extend_from_slice(&a);
        }
        p.wall = start.elapsed().as_secs_f64();
        p.dev_ms = self.soc.periph.ms() - ms0;
        p.insn0 = self.cpu.insn_count - i0;
        p.insn1 = self.cpu1.as_ref().map_or(0, |c| c.insn_count) - i1;
        p.cycles = self.soc.periph.cycles - cy;
        p.skipped = self.soc.periph.skipped - sk;
        p.lcd_frames = self.soc.lcd.frames - lf;
        p.t0 = self.t0 - tt0;
        p.t1 = self.t1 - tt1;
        p
    }
}

/// One whole bench: boot, settle, idle, chord.
pub fn run_once(pkg: &[u8], o: &Opts) -> Result<Run, String> {
    let t = Instant::now();
    let (mut m, identity) = Machine::boot(pkg, o)?;
    let mut r = Run { boot_wall: t.elapsed().as_secs_f64(), identity, ..Default::default() };
    // the chord on the device's clock (fm1_soc::script, as fm1-live's and the web build's benches queue
    // keys): the same cycle however the run is chunked, so runs and builds compare by hash
    let down = m.soc.periph.cycle_of_ms(o.settle_ms + o.idle_ms);
    for id in CHORD {
        m.soc.periph.script.push_back((down, Action::Key { id, down: true }));
    }
    r.settle = m.phase(o.settle_ms);
    r.idle = m.phase(o.settle_ms + o.idle_ms);
    #[cfg(feature = "fork-stats")]
    let st0 = m.cpu.stats;
    r.chord = m.phase(o.settle_ms + o.idle_ms + o.chord_ms);
    #[cfg(feature = "fork-stats")]
    {
        let d: Vec<u64> = (0..4).map(|i| m.cpu.stats[i] - st0[i]).collect();
        eprintln!(
            "stats (chord, cpu0): {} block entries, {:.2} insns per block, {:.1}% of entries over RAM, {} RAM block compares ({:.1} bytes each)",
            d[0],
            r.chord.insn0 as f64 / d[0].max(1) as f64,
            100.0 * d[1] as f64 / d[0].max(1) as f64,
            d[2],
            d[3] as f64 / d[2].max(1) as f64
        );
    }
    r.cpu1_at_ms = m.cpu1.as_ref().map(|_| 0);
    let fb = &m.soc.lcd.fb;
    r.lcd_lit = fb.iter().filter(|&&p| p != 0).count();
    let mut colors: Vec<u16> = fb.clone();
    colors.sort_unstable();
    colors.dedup();
    r.lcd_colors = colors.len();
    // SAFETY: plain u16 slice viewed as bytes
    r.lcd_hash = fnv(FNV0, unsafe { std::slice::from_raw_parts(fb.as_ptr() as *const u8, fb.len() * 2) });
    // the first (total - 1 s) of device time in frames (44117.647 frames/s, fm1-soc I2S clock; the DMA starts within 1 s)
    let keep = (((o.settle_ms + o.idle_ms + o.chord_ms).saturating_sub(1000)) as f64 * 44.117647) as usize * 2;
    let a = &m.audio_all[..keep.min(m.audio_all.len())];
    // SAFETY: plain i16 slice viewed as bytes
    r.audio_hash = fnv(FNV0, unsafe { std::slice::from_raw_parts(a.as_ptr() as *const u8, a.len() * 2) });
    r.halted = m.halted.clone();
    r.pc0 = m.cpu.pc;
    if std::env::var_os("FM1B_PC").is_some() {
        eprintln!("cpu0 pc {:#010x} lr {:#010x} r0..r3 {:x?} 0x10008={:#x} [0x01c7fff8]={:#x}", m.cpu.pc, m.cpu.rets, &m.cpu.regs[..4], m.soc.read32(0x10008), m.soc.read32(0x01c7fff8));
    }
    if o.routes {
        let tot: u64 = m.cpu.route_hist.iter().sum();
        let slow = tot - m.cpu.route_hist[31];
        r.slow_share = Some(slow as f64 / m.cpu.insn_count.max(1) as f64);
    }
    Ok(r)
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if v.is_empty() { 0.0 } else { v[v.len() / 2] }
}

pub fn line(name: &str, i: usize, r: &Run, o: &Opts) -> String {
    let ph = |p: &Phase| {
        let split = if o.split {
            let tot = (p.t0 + p.t1).max(1e-9);
            format!(" cpu0 {:.0}% cpu1 {:.0}% of wall", 100.0 * p.t0 / tot, 100.0 * p.t1 / tot)
        } else {
            String::new()
        };
        format!(
            "{:.3}x ({:.2} s dev / {:.2} s wall; cpu0 {:.1} M insn/dev-s, cpu1 {:.1} M; idle-skipped {:.0}% of cycles; {:.1} M insn/wall-s; rms {:.1} dBFS peak {}; lcd frames {}{split})",
            p.xrt(),
            p.dev_ms as f64 / 1000.0,
            p.wall,
            p.insn0 as f64 / 1e3 / p.dev_ms.max(1) as f64,
            p.insn1 as f64 / 1e3 / p.dev_ms.max(1) as f64,
            100.0 * p.skipped as f64 / p.cycles.max(1) as f64,
            (p.insn0 + p.insn1) as f64 / 1e6 / p.wall.max(1e-9),
            p.rms_dbfs(),
            p.peak,
            p.lcd_frames
        )
    };
    format!(
        "{name} run {i}: boot+settle {:.3}x | idle {} | chord {} | lcd {} lit px, {} colours, hash {:016x} | audio hash {:016x} | cpu1 {} | halted {}{}\n",
        r.settle.xrt(),
        ph(&r.idle),
        ph(&r.chord),
        r.lcd_lit,
        r.lcd_colors,
        r.lcd_hash,
        r.audio_hash,
        if r.cpu1_at_ms.is_some() { "running" } else { "never released" },
        r.halted.as_deref().unwrap_or("no"),
        r.slow_share.map_or(String::new(), |s| format!(" | slow path {:.2}% of cpu0 insns", 100.0 * s)),
    )
}

/// `runs` benches of one package; the report, and each line as it is made through `log`.
pub fn bench(name: &str, pkg: &[u8], o: &Opts, runs: usize, log: &mut dyn FnMut(&str)) -> String {
    let mut out = String::new();
    let head = format!(
        "== {name}: {} MHz, {} ({}), settle {} ms, idle {} ms, chord C4 E4 G4 {} ms, {} runs{}\n",
        o.mhz,
        if o.jit && JIT_COMPILED { "JIT" } else { "interpreter" },
        if JIT_COMPILED { "JIT compiled in" } else { "no JIT in this build" },
        o.settle_ms,
        o.idle_ms,
        o.chord_ms,
        runs,
        if o.split { ", split timing" } else { "" }
    );
    log(&head);
    out += &head;
    let mut all = Vec::new();
    for i in 0..runs {
        match run_once(pkg, o) {
            Ok(r) => {
                let l = line(name, i + 1, &r, o);
                log(&l);
                out += &l;
                all.push(r);
            }
            Err(e) => {
                let l = format!("{name} run {}: error {e}\n", i + 1);
                log(&l);
                out += &l;
                return out;
            }
        }
    }
    let same = all.windows(2).all(|w| w[0].audio_hash == w[1].audio_hash && w[0].lcd_hash == w[1].lcd_hash);
    let l = format!(
        "{name} MEDIAN: idle {:.3}x  chord {:.3}x  (chord rms {:.1} dBFS, lcd {} lit px; runs deterministic: {})\n",
        median(all.iter().map(|r| r.idle.xrt()).collect()),
        median(all.iter().map(|r| r.chord.xrt()).collect()),
        all[0].chord.rms_dbfs(),
        all[0].lcd_lit,
        if same { "yes" } else { "NO" }
    );
    log(&l);
    out += &l;
    out
}

/// C entry point: `runs` benches of the package `pkg[..len]`, named `name`. Writes a NUL-
/// terminated report (truncated to `cap`) into `out`; `log` (may be NULL) gets each line as it
/// is made. `jit` is ignored where the JIT is not compiled in (iOS). Returns 0, or 1 on a panic.
#[no_mangle]
pub extern "C" fn fm1b_bench(
    pkg: *const u8,
    len: usize,
    name: *const std::os::raw::c_char,
    mhz: u32,
    jit: i32,
    runs: u32,
    split: i32,
    settle_ms: u32,
    idle_ms: u32,
    chord_ms: u32,
    out: *mut u8,
    cap: usize,
    log: Option<extern "C" fn(*const std::os::raw::c_char)>,
) -> i32 {
    let res = std::panic::catch_unwind(|| {
        // SAFETY: the caller passes a valid buffer and a NUL-terminated name
        let pkg = unsafe { std::slice::from_raw_parts(pkg, len) };
        let name = unsafe { std::ffi::CStr::from_ptr(name) }.to_string_lossy().into_owned();
        let o = Opts {
            mhz: mhz as u64,
            jit: jit != 0,
            split: split != 0,
            settle_ms: settle_ms as u64,
            idle_ms: idle_ms as u64,
            chord_ms: chord_ms as u64,
            routes: false,
        };
        let mut cb = |s: &str| {
            eprint!("{s}");
            if let Some(f) = log {
                if let Ok(c) = std::ffi::CString::new(s) {
                    f(c.as_ptr());
                }
            }
        };
        bench(&name, pkg, &o, runs as usize, &mut cb)
    });
    let (text, rc) = match res {
        Ok(t) => (t, 0),
        Err(_) => ("panic\n".to_owned(), 1),
    };
    if cap > 0 && !out.is_null() {
        let n = text.len().min(cap - 1);
        // SAFETY: out has room for cap bytes
        unsafe {
            std::ptr::copy_nonoverlapping(text.as_ptr(), out, n);
            *out.add(n) = 0;
        }
    }
    rc
}

/// 1 when fm1-core's JIT is compiled into this build (never on iOS).
#[no_mangle]
pub extern "C" fn fm1b_jit_compiled() -> i32 {
    JIT_COMPILED as i32
}

/// Where the guest spends its instructions during the chord: cpu0 sampled every `every` instructions
/// (pc, inside an interrupt handler or not). The sampling cuts blocks short, so it is slower; it is
/// for the guest-side breakdown only, never for timing.
pub fn guest_profile(pkg: &[u8], o: &Opts, every: u32) -> Result<String, String> {
    let (mut m, _) = Machine::boot(pkg, o)?;
    let down = m.soc.periph.cycle_of_ms(o.settle_ms + o.idle_ms);
    // FM1B_NOKEYS: sample the same span with no chord (the idle firmware)
    for id in if std::env::var_os("FM1B_NOKEYS").is_some() { &[][..] } else { &CHORD[..] } {
        let id = *id;
        m.soc.periph.script.push_back((down, Action::Key { id, down: true }));
    }
    let _ = m.phase(o.settle_ms + o.idle_ms);
    let end = o.settle_ms + o.idle_ms + o.chord_ms;
    let mut pcs: std::collections::HashMap<u32, (u64, u64)> = Default::default();
    let (mut isr, mut main, mut depth2) = (0u64, 0u64, 0u64);
    let mut isr_insn = 0u64;
    let mut main_insn = 0u64;
    while m.soc.periph.ms() < end && m.halted.is_none() {
        let in_isr = !m.cpu.irq_levels.is_empty();
        let i0 = m.cpu.insn_count;
        m.run(every);
        let di = m.cpu.insn_count - i0;
        m.soc.periph.audio.clear();
        let e = pcs.entry(m.cpu.pc).or_default();
        if in_isr {
            isr += 1;
            isr_insn += di;
            e.0 += 1;
            if m.cpu.irq_levels.len() > 1 {
                depth2 += 1;
            }
        } else {
            main += 1;
            main_insn += di;
            e.1 += 1;
        }
    }
    let tot = (isr + main).max(1);
    let mut out = format!(
        "guest profile (chord, cpu0, a sample every {every} instructions): in an ISR {:.1}% of samples ({:.1}% of instructions), main loop {:.1}% ({:.1}%), nested ISR {:.1}%\n",
        100.0 * isr as f64 / tot as f64,
        100.0 * isr_insn as f64 / (isr_insn + main_insn).max(1) as f64,
        100.0 * main as f64 / tot as f64,
        100.0 * main_insn as f64 / (isr_insn + main_insn).max(1) as f64,
        100.0 * depth2 as f64 / tot as f64
    );
    let mut v: Vec<_> = pcs.into_iter().collect();
    v.sort_by(|a, b| (b.1 .0 + b.1 .1).cmp(&(a.1 .0 + a.1 .1)));
    for (pc, (i, mn)) in v.iter().take(30) {
        out += &format!("  pc {pc:#010x} {:5.2}%  (isr {i}, main {mn})\n", 100.0 * (i + mn) as f64 / tot as f64);
    }
    Ok(out)
}
