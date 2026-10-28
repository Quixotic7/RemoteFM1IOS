#!/bin/sh
# Interleaved A/B/C... of fm1bench builds (back-to-back runs drift; the machine is shared).
# usage: tools/ab.sh ROUNDS "ARGS" BIN1 BIN2 ...   (prints each build's chord x per round, and its hashes)
ROUNDS=$1; ARGS=$2; shift 2
r=1
while [ $r -le "$ROUNDS" ]; do
  for b in "$@"; do
    # shellcheck disable=SC2086
    "$b" --runs 1 $ARGS | grep " run 1" | sed -E "s/^([a-z0-9.-]+) run 1: .*idle ([0-9.]+x).*chord ([0-9.]+x).*lcd [0-9]+ lit px, [0-9]+ colours, hash ([0-9a-f]+) \| audio hash ([0-9a-f]+).*/round $r \1 idle \2 chord \3 lcd \4 audio \5/" | sed "s|^|$b |"
  done
  r=$((r + 1))
done
