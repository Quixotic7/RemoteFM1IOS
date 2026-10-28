#!/usr/bin/env python3
"""Leaf-address profile from an xctrace Time Profiler export (time-profile table XML):
each sample's leaf pc in fm1bench, symbolised with `atos -i` (inlined frames, file:line), then
bucketed by the innermost fm1-emu function / source line.

usage: leafprof.py export.xml BINARY [top]
"""
import collections, subprocess, sys
import xml.etree.ElementTree as ET

xml, binary = sys.argv[1], sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
frames, bins, leaf = {}, {}, collections.Counter()
total = 0
for ev, el in ET.iterparse(xml, events=("end",)):
    if el.tag == "binary" and "id" in el.attrib:
        bins[el.attrib["id"]] = el.attrib
    if el.tag == "frame" and "id" in el.attrib:
        b = el.find("binary")
        bid = b.attrib.get("id") or b.attrib.get("ref") if b is not None else None
        frames[el.attrib["id"]] = (int(el.attrib.get("addr", "0"), 16), bid, el.attrib.get("name", "?"))
    if el.tag == "row":
        bt = el.find("tagged-backtrace")
        if bt is None:
            bt = el.find("backtrace")
        if bt is None:
            el.clear(); continue
        if "ref" in bt.attrib and not list(bt):
            f = bt_first.get(bt.attrib["ref"]) if "bt_first" in globals() else None
        else:
            f0 = list(bt)[0]
            f = f0.attrib.get("id") or f0.attrib.get("ref")
            globals().setdefault("bt_first", {})[bt.attrib.get("id")] = f
        total += 1
        if f:
            leaf[f] += 1
        el.clear()

load = None
by_addr = collections.Counter()
other = collections.Counter()
for fid, n in leaf.items():
    addr, bid, name = frames[fid]
    b = bins.get(bid, {})
    if b.get("path", "").endswith("fm1bench"):
        load = b["load-addr"]
        by_addr[addr] += n
    else:
        other[(b.get("name", "?"), name)] += n

addrs = sorted(by_addr)
out = subprocess.run(["atos", "-i", "-o", binary, "-l", load] + [hex(a) for a in addrs], capture_output=True, text=True).stdout
# atos -i: one or more lines per address (innermost first), blank line between addresses
blocks = out.strip("\n").split("\n\n")
fn = collections.Counter(); line = collections.Counter(); cat = collections.Counter()

MEM = ("read8", "read16", "read32", "write8", "write16", "write32", "region", "wrote", "ld_w", "st_w",
       "sfr_get", "sfr_set", "timer_read")
PER = ("Periph", "Lcd", "advance", "led_", "next_event", "pending_irq", "any_pending", "SpiFlash", "push_pixel",
       "feed", "Uart", "apply")
EXE = ("alu_f", "alu", "add_flags", "cond_true", "cmp_cond", "exec_rare", "exec_raw", "exec_careful",
       "exec_fast_paired", "finish", "exec_syntax", "execute", "fpu", "replace<core::option::Option<([u32")
BLK = ("block_at", "build_block", "ram_block_ok", "ram_block_current", "ram_code", "fetch", "same_bytes")
DUAL = ("run_cpu1", "run_dual", "released_cpu1", "Core1Bus", "core_paused")


def classify(chain):
    for name, loc in chain:
        base = name.split("<")[0]
        if base == "tick" or base.endswith("4tick") or base.endswith("tick"):
            return "tick (cycle count + due check)"
        if any(k in name for k in DUAL):
            return "dual-core scheduling"
        if any(k in base for k in MEM):
            return "memory access (bus, RAM/XIP fast paths, MMIO)"
        if any(k in name for k in PER):
            return "peripherals / SoC service"
        if any(k in name for k in BLK):
            return "block lookup (bmap, RAM block check)"
        if any(base.startswith(k) or ("3Cpu" in base and k in base) for k in EXE):
            return "execute handlers"
        if base.startswith("exec_fast"):
            return "dispatch (exec_fast match)" if loc.endswith(":968") else "execute handlers"
        if "run_fast" in name:
            ln = loc.split(":")[-1]
            if ln == "522":
                return "tick (cycle count + due check)"
            if ln in ("425", "426", "427", "428", "429", "430", "431", "432", "433", "434", "439"):
                return "block lookup (bmap, RAM block check)"
            return "block loop (op load, pc/count, branch-out)"
        if "run_blocks" in name:
            return "peripherals / SoC service"
    return "other: " + chain[0][0][:50]
for a, blk in zip(addrs, blocks):
    lines = [l for l in blk.split("\n") if l.strip()]
    inner = lines[0] if lines else "?"
    name = inner.split(" (in ")[0]
    loc = inner[inner.rfind("(") + 1: inner.rfind(")")] if "(" in inner else "?"
    fn[name] += by_addr[a]
    chain = []
    for l in lines:
        nm = l.split(" (in ")[0]
        lc = l[l.rfind("(") + 1: l.rfind(")")] if "(" in l else "?"
        chain.append((nm, lc))
    cat[classify(chain) if chain else "?"] += by_addr[a]
    line[loc + "  " + name[:60]] += by_addr[a]
print(f"samples {total}, in fm1bench {sum(by_addr.values())}")
print("-- category")
for k, v in cat.most_common():
    print(f"{100*v/total:6.2f}%  {k}")
print("-- innermost function")
for k, v in fn.most_common(top):
    print(f"{100*v/total:6.2f}%  {k[:120]}")
print("-- innermost source line")
for k, v in line.most_common(top):
    print(f"{100*v/total:6.2f}%  {k[:150]}")
print("-- outside fm1bench")
for k, v in other.most_common(8):
    print(f"{100*v/total:6.2f}%  {k}")
