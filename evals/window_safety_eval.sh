#!/bin/bash
# Safety eval: with the panel EXPANDED, no Vibenotch window may be larger than 1000x700,
# and window layer must be <= 25 (statusBar), never screensaver (1000).
set +e
cd "$(dirname "$0")/.."
pkill -f "Vibenotch.app" 2>/dev/null; sleep 1
open build/Vibenotch.app; sleep 4
# expand via hover
for y in 60 30 10 4 3; do ./tools/movemouse 1028 $y >/dev/null 2>&1; sleep 0.2; done
sleep 1.2
FAIL=0
while IFS= read -r line; do
  W=$(echo "$line" | sed -E 's/.* w=([0-9.]+).*/\1/'); H=$(echo "$line" | sed -E 's/.* h=([0-9.]+).*/\1/')
  L=$(echo "$line" | sed -E 's/.*layer=(-?[0-9]+).*/\1/')
  Wi=${W%.*}; Hi=${H%.*}
  echo "  $line"
  if [ "${Wi:-0}" -gt 1000 ] && [ "${Hi:-0}" -gt 700 ]; then echo "  ^ FAIL: oversized window"; FAIL=1; fi
  if [ "${L:-0}" -gt 25 ]; then echo "  ^ FAIL: layer too high ($L)"; FAIL=1; fi
done < <(./tools/notchwindows)
# click far outside must dismiss the INTERACTIVE panel (width 600-760 band)
INTERACTIVE_BEFORE=$(./tools/notchwindows | awk '/w=6[0-9][0-9]\.|w=7[0-5][0-9]\./' | wc -l | tr -d ' ')
./tools/clickat 300 900 >/dev/null 2>&1; sleep 1.5
INTERACTIVE_AFTER=$(./tools/notchwindows | awk '/w=6[0-9][0-9]\.|w=7[0-5][0-9]\./' | wc -l | tr -d ' ')
echo "interactive panels before=$INTERACTIVE_BEFORE after=$INTERACTIVE_AFTER"
if [ "${INTERACTIVE_BEFORE:-0}" -lt 1 ]; then echo "FAIL: interactive panel never appeared"; FAIL=1; fi
if [ "${INTERACTIVE_AFTER:-0}" -gt 0 ]; then echo "FAIL: interactive panel survived outside click"; FAIL=1; fi
pkill -f "Vibenotch.app" 2>/dev/null
[ "$FAIL" -eq 0 ] && echo "WINDOW SAFETY EVAL: PASS" || { echo "WINDOW SAFETY EVAL: FAIL"; exit 1; }
