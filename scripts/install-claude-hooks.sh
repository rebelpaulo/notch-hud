#!/bin/sh

# Additively merges NotchHUD's five Claude Code hooks into settings.json.
# Never touches unrelated keys or unrelated hook entries (e.g. an existing
# `rtk hook claude` PreToolUse matcher). Idempotent: re-running detects our
# entries by the notch-claude-hook path and skips. `--uninstall` reverses
# it by removing only entries whose command contains that path.
#
# Env overrides (used by tests so they never touch the real files):
#   NOTCH_HUD_INSTALL_PREFIX      default $HOME/.notch-hud
#   NOTCH_INSTALL_CLAUDE_SETTINGS default $HOME/.claude/settings.json

set -eu

install_prefix=${NOTCH_HUD_INSTALL_PREFIX:-"$HOME/.notch-hud"}
settings_path=${NOTCH_INSTALL_CLAUDE_SETTINGS:-"$HOME/.claude/settings.json"}
hook_path=$install_prefix/bin/notch-claude-hook
timestamp=$(date -u +%Y%m%d%H%M%S)

mode=install
case ${1:-} in
    --uninstall) mode=uninstall ;;
    "") ;;
    *)
        printf '%s\n' "notch-hud: opção desconhecida para install-claude-hooks.sh: $1" >&2
        exit 64
        ;;
esac

command -v python3 >/dev/null 2>&1 || {
    printf '%s\n' "notch-hud: 'python3' em falta; não é possível atualizar $settings_path" >&2
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
        print(f"notch-hud: {path} não é JSON válido ({exc}); não foi tocado", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"notch-hud: {path} não contém um objeto JSON; não foi tocado", file=sys.stderr)
        sys.exit(1)
else:
    data = {}

hooks = data.get("hooks")
if hooks is None:
    hooks = {}
elif not isinstance(hooks, dict):
    print(f"notch-hud: {path} tem uma chave \"hooks\" que não é um objeto; não foi tocado", file=sys.stderr)
    sys.exit(1)
data["hooks"] = hooks

OUR_EVENTS = [
    ("UserPromptSubmit", None, "working"),
    ("PreToolUse", "*", "tool"),
    ("Stop", None, "done"),
    ("Notification", None, "notify"),
    ("SessionEnd", None, "remove"),
]


def has_our_hook(entry):
    if not isinstance(entry, dict):
        return False
    for h in entry.get("hooks", []):
        if isinstance(h, dict) and hook_path in str(h.get("command", "")):
            return True
    return False


def install():
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


if mode == "uninstall":
    uninstall()
else:
    install()

print(json.dumps(data, indent=2))
PY
) || exit 1

if [ "$after" = "$before" ]; then
    if [ "$mode" = uninstall ]; then
        printf '%s\n' "Hooks do Claude Code: skipped (nada para remover)"
    else
        printf '%s\n' "Hooks do Claude Code: skipped (já instalados)"
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
    printf '%s\n' "Hooks do Claude Code: changed (removidos; cópia de segurança em $settings_path.bak.$timestamp)"
else
    printf '%s\n' "Hooks do Claude Code: changed (cópia de segurança em $settings_path.bak.$timestamp)"
fi
