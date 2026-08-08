#!/bin/sh

# Additively merges Vibenotch's five Claude Code hooks into settings.json.
# Never touches unrelated keys or unrelated hook entries (e.g. an existing
# `rtk hook claude` PreToolUse matcher). Idempotent: re-running detects our
# entries by the vibenotch-claude-hook path and skips. `--uninstall` reverses
# it by removing only entries whose command contains that path.
#
# Env overrides (used by tests so they never touch the real files):
#   VIBENOTCH_INSTALL_PREFIX      default $HOME/.vibenotch
#   VIBENOTCH_INSTALL_CLAUDE_SETTINGS default $HOME/.claude/settings.json

set -eu

install_prefix=${VIBENOTCH_INSTALL_PREFIX:-"$HOME/.vibenotch"}
settings_path=${VIBENOTCH_INSTALL_CLAUDE_SETTINGS:-"$HOME/.claude/settings.json"}
hook_path=$install_prefix/bin/vibenotch-claude-hook
timestamp=$(date -u +%Y%m%d%H%M%S)

mode=install
case ${1:-} in
    --uninstall) mode=uninstall ;;
    "") ;;
    *)
        printf '%s\n' "vibenotch: unknown option for install-claude-hooks.sh: $1" >&2
        exit 64
        ;;
esac

command -v python3 >/dev/null 2>&1 || {
    printf '%s\n' "vibenotch: 'python3' is missing; cannot update $settings_path" >&2
    exit 1
}

mkdir -p "$(dirname "$settings_path")" || exit 1

before=
[ -f "$settings_path" ] && before=$(cat "$settings_path")

after=$(python3 - "$settings_path" "$hook_path" "$mode" <<'PY'
import json
import sys

path, hook_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(path) as f:
        raw = f.read()
except FileNotFoundError:
    raw = ""

if raw.strip():
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"vibenotch: {path} is not valid JSON ({exc}); left untouched", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"vibenotch: {path} does not contain a JSON object; left untouched", file=sys.stderr)
        sys.exit(1)
else:
    data = {}

hooks = data.get("hooks")
if hooks is None:
    hooks = {}
elif not isinstance(hooks, dict):
    print(f"vibenotch: {path} has a \"hooks\" key that is not an object; left untouched", file=sys.stderr)
    sys.exit(1)
data["hooks"] = hooks

OUR_EVENTS = [
    ("UserPromptSubmit", None, "working"),
    ("PreToolUse", "*", "tool"),
    ("Stop", None, "done"),
    ("Notification", None, "notify"),
    ("SessionEnd", None, "remove"),
]


# Historical literal: the pre-rename hook path. Upgrading users still have
# these five entries pointing at ~/.notch-hud, which writes to a spool the app
# no longer reads — so every session would be recorded twice, once into a
# directory nobody watches. Must NOT be swept along by a future rename.
LEGACY_HOOK_PATH = "/.notch-hud/bin/notch-claude-hook"


def hook_commands(entry):
    if not isinstance(entry, dict):
        return []
    return [str(h.get("command", "")) for h in entry.get("hooks", []) if isinstance(h, dict)]


def has_our_hook(entry):
    return any(hook_path in command for command in hook_commands(entry))


def is_legacy_hook(entry):
    return any(LEGACY_HOOK_PATH in command for command in hook_commands(entry))


def drop_legacy():
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        remaining = [entry for entry in entries if not is_legacy_hook(entry)]
        if len(remaining) == len(entries):
            continue
        if remaining:
            hooks[event] = remaining
        else:
            del hooks[event]


def install():
    drop_legacy()
    for event, matcher, verb in OUR_EVENTS:
        entries = hooks.get(event)
        if not isinstance(entries, list):
            entries = []
        if any(has_our_hook(entry) for entry in entries):
            hooks[event] = entries
            continue
        new_entry = {"hooks": [{"type": "command", "command": f"{hook_path} {verb}"}]}
        if matcher is not None:
            new_entry = {"matcher": matcher, **new_entry}
        entries.append(new_entry)
        hooks[event] = entries


def uninstall():
    drop_legacy()
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        remaining = [entry for entry in entries if not has_our_hook(entry)]
        if remaining:
            hooks[event] = remaining
        else:
            del hooks[event]
    if not hooks:
        data.pop("hooks", None)


original = json.loads(json.dumps(data))

if mode == "uninstall":
    uninstall()
else:
    install()

# Echo the file back byte-for-byte when nothing actually changed:
# re-serializing would reformat a hand-indented settings.json and the caller
# would read that as "changed", back it up and rewrite it for no reason.
print(raw, end="") if data == original and raw else print(json.dumps(data, indent=2))
PY
) || exit 1

if [ "$after" = "$before" ]; then
    if [ "$mode" = uninstall ]; then
        printf '%s\n' "Claude Code hooks: skipped (nothing to remove)"
    else
        printf '%s\n' "Claude Code hooks: skipped (already installed)"
    fi
    exit 0
fi

if [ -f "$settings_path" ]; then
    cp "$settings_path" "$settings_path.bak.$timestamp" || exit 1
fi
temp_file=$settings_path.tmp.$$
printf '%s\n' "$after" > "$temp_file" || exit 1
mv "$temp_file" "$settings_path" || exit 1

if [ "$mode" = uninstall ]; then
    printf '%s\n' "Claude Code hooks: changed (removed; backup at $settings_path.bak.$timestamp)"
else
    printf '%s\n' "Claude Code hooks: changed (backup at $settings_path.bak.$timestamp)"
fi
