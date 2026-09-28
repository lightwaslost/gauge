#!/usr/bin/env bash
# Records a scripted walkthrough of Gauge. Gauge must be running with --demo.
# Usage: scripts/demo/tour.sh <recorder-binary> <output.mov>
set -euo pipefail
cd "$(dirname "$0")/../.."
RECORDER=$1
OUT=$2
post() { scripts/demo/post.sh "$1"; }
wait_s() { python3 -c "import time; time.sleep($1)"; }

post resize:1440x900
post section:overview
wait_s 3

"$RECORDER" Gauge "$OUT" 240 > /tmp/gauge-recorder.log 2>&1 &
REC=$!
wait_s 1.5
SHEETS=1
grep -q "off screen" /tmp/gauge-recorder.log && SHEETS=0

# Overview
wait_s 4.5
post scroll:down;     wait_s 3
if [[ $SHEETS == 1 ]]; then
  post openApp;       wait_s 5
  post closeSheet;    wait_s 1.5
fi
post scroll:down;     wait_s 2.5

# Resources
post section:cpu;     wait_s 4.5
post scroll:down;     wait_s 3
post section:memory;  wait_s 4
post scroll:down;     wait_s 3.5
post section:disk;    wait_s 4
post scroll:down;     wait_s 3
post section:network; wait_s 4
post scroll:down;     wait_s 3
post section:storage; wait_s 1
post scanStorage;     wait_s 6
post scroll:down;     wait_s 3.5
post section:graphics; wait_s 4
post section:battery; wait_s 5

# Workspace
post section:apps;    wait_s 4
post section:projects; wait_s 5
post section:history; wait_s 4.5
post scroll:down;     wait_s 3
post section:alerts;  wait_s 3.5
post saveMoment:"Chrome was busy during the recording"
post section:moments; wait_s 5
post section:overview; wait_s 3.5

kill -INT $REC
wait $REC || true
cat /tmp/gauge-recorder.log
