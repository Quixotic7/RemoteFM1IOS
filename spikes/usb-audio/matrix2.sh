#!/bin/sh
# Step 5: small output IO buffers with a busy render callback; the last one overloads it (a positive control).
cd "$(dirname "$0")"
L="--freq 1503 --db -18"
echo "== h64 none buffer 64 busy 1100 us"; ./run.sh h64 none 0 30 $L --buffer 64 --busy-us 1100; sleep 2
echo "== h128 none buffer 128 busy 2300 us"; ./run.sh h128 none 0 30 $L --buffer 128 --busy-us 2300; sleep 2
echo "== h64n noise 280000 buffer 64 busy 1100 us"; ./run.sh h64n noise 280000 30 $L --buffer 64 --busy-us 1100; sleep 2
echo "== x64 none buffer 64 busy 1600 us (overload)"; ./run.sh x64 none 0 30 $L --buffer 64 --busy-us 1600
echo done
