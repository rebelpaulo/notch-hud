#!/bin/sh

# Additively merges Vibenotch's five Claude Code hooks and status-line bridge
# into settings.json.
# Never touches unrelated keys or unrelated hook entries (e.g. an existing
# `rtk hook claude` PreToolUse matcher). Idempotent: re-running detects our
# entries by the vibenotch-claude-hook path and skips. `--uninstall` reverses
# it by removing only entries whose command contains that path.  A pre-existing
# statusLine is kept in an atomic sidecar and restored on uninstall.
#
# Env overrides (used by tests so they never touch the real files):
#   VIBENOTCH_INSTALL_PREFIX      default $HOME/.vibenotch
#   VIBENOTCH_INSTALL_CLAUDE_SETTINGS default $HOME/.claude/settings.json

set -eu

install_prefix=${VIBENOTCH_INSTALL_PREFIX:-"$HOME/.vibenotch"}
settings_path=${VIBENOTCH_INSTALL_CLAUDE_SETTINGS:-"$HOME/.claude/settings.json"}
hook_path=$install_prefix/bin/vibenotch-claude-hook
statusline_path=$install_prefix/bin/vibenotch-claude-statusline
statusline_chain_path=$install_prefix/claude-statusline-chain.json
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

mkdir -p "$(dirname "$settings_path")" "$install_prefix" || exit 1

python3 - "$settings_path" "$hook_path" "$statusline_path" "$statusline_chain_path" "$mode" "$timestamp" <<'PY'
import copy
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import sys
import tempfile

path, hook_path, statusline_path, chain_path, mode, timestamp = sys.argv[1:]
settings_path = Path(path)
chain_path = Path(chain_path)
BRIDGE_NAME = "vibenotch-claude-statusline"


def warning(message):
    print(f"vibenotch: Claude statusLine {message}", file=sys.stderr)


def atomic_bytes_write(destination, content, permissions):
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=destination.parent,
        prefix=f".{destination.name}.tmp.",
    )
    try:
        os.fchmod(descriptor, permissions)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, destination)
        os.chmod(destination, permissions)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def atomic_json_write(destination, value):
    content = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    atomic_bytes_write(destination, content, 0o600)


def status_line_command(value):
    if not isinstance(value, dict):
        return None
    command = value.get("command")
    return command if isinstance(command, str) else None


def command_executable(command, recursion=0):
    """Return the executable a shell command would directly dispatch.

    This deliberately understands only common transparent wrappers. Unknown
    shell syntax is left alone and the runtime depth guard remains the final
    protection; a textual mention of our filename must never be mistaken for
    execution and overwrite somebody else's status line.
    """
    if not isinstance(command, str) or recursion > 4:
        return None
    try:
        words = shlex.split(command)
    except ValueError:
        return None
    index = 0
    while index < len(words) and "=" in words[index] and not words[index].startswith("/"):
        name = words[index].split("=", 1)[0]
        if not name.replace("_", "a").isalnum() or name[:1].isdigit():
            break
        index += 1
    if index >= len(words):
        return None

    executable = words[index]
    basename = os.path.basename(executable)
    if basename in ("command", "exec", "nohup"):
        return command_executable(" ".join(shlex.quote(word) for word in words[index + 1:]), recursion + 1)
    if basename == "env":
        index += 1
        while index < len(words):
            word = words[index]
            if word in ("-i", "--ignore-environment"):
                index += 1
                continue
            if word in ("-u", "--unset") and index + 1 < len(words):
                index += 2
                continue
            if word.startswith("--unset="):
                index += 1
                continue
            if "=" in word and not word.startswith("/"):
                index += 1
                continue
            break
        return words[index] if index < len(words) else None
    if basename in ("sh", "bash", "zsh"):
        try:
            command_index = words.index("-c", index + 1) + 1
        except (ValueError, IndexError):
            return executable
        return command_executable(words[command_index], recursion + 1)
    return executable


def invokes_bridge(command):
    executable = command_executable(command)
    if executable is None:
        return False
    if os.path.basename(executable) == BRIDGE_NAME:
        return True
    if os.path.normpath(executable) == os.path.normpath(statusline_path):
        return True
    try:
        return os.path.samefile(executable, statusline_path)
    except (FileNotFoundError, OSError):
        return False


def invokes_current_bridge(command):
    executable = command_executable(command)
    if executable is None:
        return False
    if os.path.normpath(executable) == os.path.normpath(statusline_path):
        return True
    try:
        return os.path.samefile(executable, statusline_path)
    except (FileNotFoundError, OSError):
        return False


def chain_is_circular(chain):
    if not isinstance(chain, dict) or not chain.get("present"):
        return False
    return invokes_bridge(status_line_command(chain.get("status_line")))


def load_chain():
    try:
        raw = chain_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "missing", None
    except (OSError, UnicodeDecodeError):
        return "invalid", None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return "invalid", None
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != 1
        or not isinstance(value.get("present"), bool)
        or (value["present"] and "status_line" not in value)
    ):
        return "invalid", None
    if chain_is_circular(value):
        return "circular", value
    return "valid", value

try:
    raw_bytes = settings_path.read_bytes()
except FileNotFoundError:
    raw_bytes = b""

try:
    raw = raw_bytes.decode("utf-8")
except UnicodeDecodeError as exc:
    print(f"vibenotch: {path} is not valid UTF-8 ({exc}); left untouched", file=sys.stderr)
    sys.exit(1)

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

original = copy.deepcopy(data)
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
    """Strip the legacy command, keeping anything sharing the same entry.

    An entry's "hooks" array can hold several commands. Dropping the whole
    entry because one of them is ours would silently delete the others.
    """
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        remaining = []
        for entry in entries:
            if not is_legacy_hook(entry):
                remaining.append(entry)
                continue
            kept = [
                h for h in entry.get("hooks", [])
                if not (isinstance(h, dict) and LEGACY_HOOK_PATH in str(h.get("command", "")))
            ]
            if kept:
                remaining.append({**entry, "hooks": kept})
        if len(remaining) == len(entries) and all(
            a is b for a, b in zip(remaining, entries)
        ):
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


if mode == "uninstall":
    uninstall()
else:
    install()

chain_state, chain = load_chain()
sidecar_changed = False

if mode == "uninstall":
    current_present = "statusLine" in data
    current_value = data.get("statusLine")
    if current_present and invokes_bridge(status_line_command(current_value)):
        if chain_state == "valid":
            if chain["present"]:
                data["statusLine"] = copy.deepcopy(chain["status_line"])
            else:
                data.pop("statusLine", None)
        else:
            data.pop("statusLine", None)
            if chain_state in ("invalid", "circular"):
                warning("removed an unsafe previous-command file during uninstall")
    if chain_path.exists():
        sidecar_changed = True
else:
    current_present = "statusLine" in data
    current_value = data.get("statusLine")
    current_command = status_line_command(current_value)

    if invokes_bridge(current_command):
        # Upgrades may move the install prefix.  Retarget the bridge without
        # ever treating the old Vibenotch command as somebody's predecessor.
        if not invokes_current_bridge(current_command):
            warning("removed an obsolete or circular Vibenotch command")
        installed_value = copy.deepcopy(current_value)
        if not isinstance(installed_value, dict):
            installed_value = {}
        installed_value["type"] = "command"
        installed_value["command"] = shlex.quote(statusline_path)
        data["statusLine"] = installed_value

        if chain_state in ("missing", "invalid", "circular"):
            atomic_json_write(
                chain_path,
                {"schema_version": 1, "present": False},
            )
            sidecar_changed = True
            if chain_state != "missing":
                warning("removed a circular or malformed previous command")
    elif current_present and current_value is not None and (
        not isinstance(current_value, dict)
        or current_value.get("type") != "command"
        or not isinstance(current_command, str)
        or not current_command.strip()
    ):
        # Claude owns this schema. If another/newer implementation uses a
        # shape we do not understand, hooks are still safe to install but the
        # status line must remain the user's rather than being overwritten.
        warning("left an unsupported existing configuration untouched")
    else:
        saved = {
            "schema_version": 1,
            "present": current_present,
        }
        if current_present:
            saved["status_line"] = copy.deepcopy(current_value)
        atomic_json_write(chain_path, saved)
        sidecar_changed = True

        installed_value = copy.deepcopy(current_value) if isinstance(current_value, dict) else {}
        installed_value["type"] = "command"
        installed_value["command"] = shlex.quote(statusline_path)
        data["statusLine"] = installed_value

settings_changed = data != original
if settings_changed:
    if settings_path.exists():
        backup = Path(f"{path}.bak.{timestamp}")
        suffix = 1
        while backup.exists():
            backup = Path(f"{path}.bak.{timestamp}.{suffix}")
            suffix += 1
        shutil.copy2(settings_path, backup)
    else:
        backup = None

    permissions = 0o600
    if settings_path.exists():
        permissions = stat.S_IMODE(settings_path.stat().st_mode)
    encoded = (json.dumps(data, indent=2) + "\n").encode()
    atomic_bytes_write(settings_path, encoded, permissions)
else:
    backup = None

if mode == "uninstall" and chain_path.exists():
    chain_path.unlink()

changed = settings_changed or sidecar_changed
if mode == "uninstall":
    if changed:
        detail = f"; backup at {backup}" if backup else ""
        print(f"Claude Code hooks: changed (removed{detail})")
    else:
        print("Claude Code hooks: skipped (nothing to remove)")
elif changed:
    detail = f"backup at {backup}" if backup else "no previous settings file"
    print(f"Claude Code hooks: changed ({detail})")
else:
    print("Claude Code hooks: skipped (already installed)")
PY
