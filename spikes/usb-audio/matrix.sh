#!/bin/sh
# The run matrix (README.md): 30 s each, a 1503 Hz tone at -18 dBFS. Results in build/runs/<name>.{json,sx.log,loop.log}.
cd "$(dirname "$0")"
L="--freq 1503 --db -18"
for r in "a1 none 0" "b1 static 280000" "c1 noise 280000" "d140 noise 140000" "d70 noise 70000" "d35 noise 35000" \
         "p1 leds 280000" "a2 none 0" "c2 noise 280000" "b2 static 280000" "d140b noise 140000" "g280 gradient 280000"; do
    set -- $r
    echo "== $1 $2 $3"
    ./run.sh $1 $2 $3 30 $L
    sleep 2
done
echo "== e1 bulk noise 800000"
SXARGS="--transport bulk" ./run.sh e1 noise 800000 30 $L
echo done
