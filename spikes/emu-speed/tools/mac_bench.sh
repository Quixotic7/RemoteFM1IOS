#!/bin/sh
# The Mac numbers: interpreter and JIT at 240 MHz (3 runs each, median), a split-timing run for the stock
# firmware (the only package here that starts core 1), and the interpreter at 360 MHz for the earlier evaluation.
# usage: tools/mac_bench.sh [BIN]   (from spikes/emu-speed; writes build/mac-*.txt)
B=${1:-target/release/fm1bench}
F=build/fwsc
set -- felucca=$F/felucca.fwsc v15=$F/v15.fwsc choralroot-0.25.1=$F/choralroot.fwsc choralroot-0.27-1core=$F/cr027-1core.fwsc
for mode in interp jit; do
  J=""; [ $mode = jit ] && J=--jit
  out=build/mac-$mode-240.txt
  uptime > $out
  $B $J --runs 3 "$@" >> $out 2>&1
  $B $J --runs 1 --split v15=$F/v15.fwsc >> $out 2>&1
  uptime >> $out
done
out=build/mac-interp-360.txt
uptime > $out
$B --mhz 360 --runs 3 felucca=$F/felucca.fwsc v15=$F/v15.fwsc choralroot-0.27-1core=$F/cr027-1core.fwsc >> $out 2>&1
uptime >> $out
