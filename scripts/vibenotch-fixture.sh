#!/bin/sh

script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
emitter=$script_dir/vibenotch-emit

[ -x "$emitter" ] || exit 0

"$emitter" fixture-working claude-code working \
    --project fixture-working \
    --cwd /tmp/fixture-working \
    --detail "Working on a fixture"

"$emitter" fixture-done claude-code done \
    --project fixture-done \
    --cwd /tmp/fixture-done \
    --detail "Fixture complete"

exit 0
