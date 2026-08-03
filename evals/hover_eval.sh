#!/bin/bash
# M0/M3 hover eval: expand fires on notch + peek-edge hover, AND panel collapses after leaving.
# Must run OUTSIDE any exec sandbox (e.g. Claude Code sandboxed Bash): sandboxed NSEvent global
# monitors receive no HID events, so every hover silently fails with enters=0.
set +e
cd "$(dirname "$0")/.."
swift build >/dev/null 2>&1 || exit 1
rm -f ~/.notch-hud/hover.log
NOTCHHUD_DEBUG=1 swift run NotchHUD > .eval-run.log 2>&1 &
APP=$!
sleep 5
ENTERS=0; EXITS=0
# left-of-notch / notch / right-of-notch, all inside the specced hit zone (notch ±150)
for pt in 700 850 1028; do
  for y in 60 30 10 4 3; do ./tools/movemouse $pt $y >/dev/null 2>&1; sleep 0.2; done
  sleep 0.9
  # leave: move well below any panel (bottom half of screen), few moves to trigger monitors
  for y in 700 760 820; do ./tools/movemouse 500 $y >/dev/null 2>&1; sleep 0.25; done
  sleep 0.9
done
kill $APP 2>/dev/null; pkill -f "debug/NotchHUD" 2>/dev/null
ENTERS=$(grep -c "ENTER delivered" ~/.notch-hud/hover.log 2>/dev/null); ENTERS=${ENTERS:-0}
echo "expand triggers: $ENTERS"
EXITS=$(grep -c "EXIT delivered" ~/.notch-hud/hover.log 2>/dev/null); EXITS=${EXITS:-0}
echo "collapse triggers: $EXITS"
if [ "$ENTERS" -ge 3 ] && [ "$EXITS" -ge 3 ]; then echo "HOVER EVAL: PASS (expand+collapse)"; else echo "HOVER EVAL: FAIL (enters=$ENTERS exits=$EXITS)"; exit 1; fi
