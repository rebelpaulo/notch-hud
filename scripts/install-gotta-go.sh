#!/bin/sh

set -u

effective_uid=${VIBENOTCH_GG_EUID:-$(id -u)}
if [ "$effective_uid" != 0 ]; then
    printf '%s\n' 'vibenotch: run this installer with sudo: sudo scripts/install-gotta-go.sh' >&2
    exit 1
fi

invoking_user=${SUDO_USER:-}
invoking_uid=${SUDO_UID:-}
case $invoking_user in
    ''|*[!A-Za-z0-9._-]*)
        printf '%s\n' 'vibenotch: could not identify the user who invoked sudo' >&2
        exit 1
        ;;
esac
if [ -z "$invoking_uid" ]; then
    printf '%s\n' 'vibenotch: SUDO_UID is missing' >&2
    exit 1
fi

script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd) || exit 1
timestamp=$(date -u +%Y%m%d%H%M%S)
if [ -n "${VIBENOTCH_GG_PREFIX:-}" ]; then
    install_prefix=$VIBENOTCH_GG_PREFIX
    invoking_home=$(dirname "$install_prefix")
else
    invoking_home=$(/usr/bin/dscl . -read "/Users/$invoking_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -n "$invoking_home" ] || invoking_home=/Users/$invoking_user
    install_prefix=$invoking_home/.vibenotch
fi
install_bin=$install_prefix/bin
sudoers_dir=${VIBENOTCH_GG_SUDOERS_DIR:-/etc/sudoers.d}
launchagents_dir=${VIBENOTCH_GG_LAUNCHAGENTS_DIR:-$invoking_home/Library/LaunchAgents}
sudoers_target=$sudoers_dir/vibenotch
plist_target=$launchagents_dir/com.rebelpaulo.vibenotch.sleepguard.plist

sudoers_summary=skipped
sleepguard_summary=skipped
watchdog_summary=skipped
remote_push_summary=skipped
plist_summary=skipped
launchctl_summary=skipped

mkdir -p "$install_bin" "$sudoers_dir" "$launchagents_dir" || exit 1

backup_if_present() {
    [ -e "$1" ] || return 0
    cp -p "$1" "$1.bak.$timestamp" || exit 1
}

install_executable() {
    source_file=$1
    target_file=$2
    if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file" && [ -x "$target_file" ]; then
        return 1
    fi
    backup_if_present "$target_file"
    cp "$source_file" "$target_file" || exit 1
    chmod 755 "$target_file" || exit 1
    return 0
}

set_invoking_owner() {
    if [ -n "${VIBENOTCH_GG_PREFIX:-}${VIBENOTCH_GG_LAUNCHAGENTS_DIR:-}${VIBENOTCH_GG_SUDOERS_DIR:-}" ]; then
        return 0
    fi
    invoking_group=$(id -gn "$invoking_user") || exit 1
    chown "$invoking_user:$invoking_group" "$@" || exit 1
}

# Validate OUTSIDE the sudoers dir: nothing — not even a dot-named temp
# sudoers(5) would skip — lands there before visudo approves it.
sudoers_staging=$(mktemp -d "${TMPDIR:-/tmp}/vibenotch-sudoers.XXXXXX") || exit 1
trap 'rm -rf "$sudoers_staging"' EXIT
sudoers_temp=$sudoers_staging/vibenotch
umask 077
{
    printf '%s\n' '# Installed by Vibenotch Gotta go!.'
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n' "$invoking_user"
} > "$sudoers_temp" || exit 1
chmod 440 "$sudoers_temp" || exit 1
if ! visudo -c -f "$sudoers_temp" >/dev/null; then
    rm -f "$sudoers_temp"
    printf '%s\n' 'vibenotch: sudoers validation failed; nothing was installed in /etc/sudoers.d' >&2
    exit 1
fi
if [ -f "$sudoers_target" ] && cmp -s "$sudoers_temp" "$sudoers_target"; then
    rm -f "$sudoers_temp"
    chmod 440 "$sudoers_target" || exit 1
else
    backup_if_present "$sudoers_target"
    # cp (not mv): staging is on another filesystem-safe path; content was
    # visudo-validated above and perms are set before it becomes active.
    cp "$sudoers_temp" "$sudoers_target.tmp.$$" || { rm -f "$sudoers_target.tmp.$$"; exit 1; }
    chmod 440 "$sudoers_target.tmp.$$" || { rm -f "$sudoers_target.tmp.$$"; exit 1; }
    mv "$sudoers_target.tmp.$$" "$sudoers_target" || { rm -f "$sudoers_target.tmp.$$"; exit 1; }
    sudoers_summary=changed
fi

if install_executable "$script_dir/vibenotch-remote-push" "$install_bin/vibenotch-remote-push"; then
    remote_push_summary=changed
fi
if install_executable "$script_dir/vibenotch-sleepguard" "$install_bin/vibenotch-sleepguard"; then
    sleepguard_summary=changed
fi
if install_executable "$script_dir/vibenotch-sleepguard-watchdog" "$install_bin/vibenotch-sleepguard-watchdog"; then
    watchdog_summary=changed
fi
set_invoking_owner "$install_prefix" "$install_bin" "$install_bin/vibenotch-sleepguard" "$install_bin/vibenotch-sleepguard-watchdog" "$install_bin/vibenotch-remote-push"

plist_temp=$launchagents_dir/.vibenotch-sleepguard.$$.plist
{
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0"><dict>'
    printf '%s\n' '  <key>Label</key><string>com.rebelpaulo.vibenotch.sleepguard</string>'
    printf '  <key>ProgramArguments</key><array><string>%s/vibenotch-sleepguard-watchdog</string></array>\n' "$install_bin"
    printf '%s\n' '  <key>RunAtLoad</key><true/>'
    printf '%s\n' '  <key>StartInterval</key><integer>60</integer>'
    printf '%s\n' '</dict></plist>'
} > "$plist_temp" || exit 1
if [ -f "$plist_target" ] && cmp -s "$plist_temp" "$plist_target"; then
    rm -f "$plist_temp"
else
    backup_if_present "$plist_target"
    mv "$plist_temp" "$plist_target" || exit 1
    chmod 644 "$plist_target" || exit 1
    plist_summary=changed
fi
set_invoking_owner "$launchagents_dir" "$plist_target"

if [ -n "${VIBENOTCH_GG_LAUNCHCTL:-}" ]; then
    if "$VIBENOTCH_GG_LAUNCHCTL" bootstrap "gui/$invoking_uid" "$plist_target" >/dev/null 2>&1; then
        launchctl_summary=changed
    fi
elif [ -z "${VIBENOTCH_GG_PREFIX:-}${VIBENOTCH_GG_LAUNCHAGENTS_DIR:-}${VIBENOTCH_GG_SUDOERS_DIR:-}" ]; then
    if /bin/launchctl bootstrap "gui/$invoking_uid" "$plist_target" >/dev/null 2>&1; then
        launchctl_summary=changed
    fi
fi

# The app used to install under the NotchHUD name. Its LaunchAgent watchdog
# looks for a process that no longer exists, decides Gotta go! is gone, and
# turns `disablesleep` back off — actively fighting this install. Remove it,
# but only when the file is one we wrote (matched by our own Label / marker),
# never anything else that happens to share the path.
#
# The identifiers below are HISTORICAL LITERALS: they name the old install and
# must survive any future rename of this project, or the cleanup starts
# deleting the install it just made.
legacy_label=com.actionable.notchhud.sleepguard
legacy_plist=$launchagents_dir/$legacy_label.plist
legacy_sudoers=$sudoers_dir/notch-hud
legacy_marker='# Installed by NotchHUD All-Nighter.'
legacy_summary=absent

if [ -f "$legacy_plist" ] && grep -q "$legacy_label" "$legacy_plist"; then
    if [ -n "${VIBENOTCH_GG_LAUNCHCTL:-}" ]; then
        "$VIBENOTCH_GG_LAUNCHCTL" bootout "gui/$invoking_uid/$legacy_label" >/dev/null 2>&1
    elif [ -z "${VIBENOTCH_GG_PREFIX:-}${VIBENOTCH_GG_LAUNCHAGENTS_DIR:-}${VIBENOTCH_GG_SUDOERS_DIR:-}" ]; then
        /bin/launchctl bootout "gui/$invoking_uid/$legacy_label" >/dev/null 2>&1
    fi
    backup_if_present "$legacy_plist"
    rm -f "$legacy_plist"
    legacy_summary=removed
fi

if [ -f "$legacy_sudoers" ] && grep -qF "$legacy_marker" "$legacy_sudoers"; then
    backup_if_present "$legacy_sudoers"
    rm -f "$legacy_sudoers"
    legacy_summary=removed
fi

printf '%s\n' 'Gotta go! install summary:'
printf '  legacy NotchHUD install: %s\n' "$legacy_summary"
printf '  sudoers: %s\n' "$sudoers_summary"
printf '  vibenotch-sleepguard: %s\n' "$sleepguard_summary"
printf '  watchdog: %s\n' "$watchdog_summary"
printf '  vibenotch-remote-push: %s\n' "$remote_push_summary"
printf '  LaunchAgent plist: %s\n' "$plist_summary"
printf '  launchctl bootstrap: %s\n' "$launchctl_summary"

exit 0
