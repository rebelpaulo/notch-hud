#!/bin/sh

set -u

effective_uid=${NOTCH_AN_EUID:-$(id -u)}
if [ "$effective_uid" != 0 ]; then
    printf '%s\n' 'notch-hud: execute este instalador com sudo: sudo scripts/install-all-nighter.sh' >&2
    exit 1
fi

invoking_user=${SUDO_USER:-}
invoking_uid=${SUDO_UID:-}
case $invoking_user in
    ''|*[!A-Za-z0-9._-]*)
        printf '%s\n' 'notch-hud: não foi possível identificar o utilizador que invocou sudo' >&2
        exit 1
        ;;
esac
if [ -z "$invoking_uid" ]; then
    printf '%s\n' 'notch-hud: SUDO_UID em falta' >&2
    exit 1
fi

script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd) || exit 1
timestamp=$(date -u +%Y%m%d%H%M%S)
if [ -n "${NOTCH_AN_PREFIX:-}" ]; then
    install_prefix=$NOTCH_AN_PREFIX
    invoking_home=$(dirname "$install_prefix")
else
    invoking_home=$(/usr/bin/dscl . -read "/Users/$invoking_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -n "$invoking_home" ] || invoking_home=/Users/$invoking_user
    install_prefix=$invoking_home/.notch-hud
fi
install_bin=$install_prefix/bin
sudoers_dir=${NOTCH_AN_SUDOERS_DIR:-/etc/sudoers.d}
launchagents_dir=${NOTCH_AN_LAUNCHAGENTS_DIR:-$invoking_home/Library/LaunchAgents}
sudoers_target=$sudoers_dir/notch-hud
plist_target=$launchagents_dir/com.actionable.notchhud.sleepguard.plist

sudoers_summary=skipped
sleepguard_summary=skipped
watchdog_summary=skipped
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
    if [ -n "${NOTCH_AN_PREFIX:-}${NOTCH_AN_LAUNCHAGENTS_DIR:-}${NOTCH_AN_SUDOERS_DIR:-}" ]; then
        return 0
    fi
    invoking_group=$(id -gn "$invoking_user") || exit 1
    chown "$invoking_user:$invoking_group" "$@" || exit 1
}

sudoers_temp=$sudoers_dir/.notch-hud.$$
umask 077
{
    printf '%s\n' '# Installed by NotchHUD All-Nighter.'
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n' "$invoking_user"
} > "$sudoers_temp" || exit 1
chmod 440 "$sudoers_temp" || exit 1
if ! visudo -c -f "$sudoers_temp" >/dev/null; then
    rm -f "$sudoers_temp"
    printf '%s\n' 'notch-hud: a validação do sudoers falhou; nada foi instalado em /etc/sudoers.d' >&2
    exit 1
fi
if [ -f "$sudoers_target" ] && cmp -s "$sudoers_temp" "$sudoers_target"; then
    rm -f "$sudoers_temp"
    chmod 440 "$sudoers_target" || exit 1
else
    backup_if_present "$sudoers_target"
    mv "$sudoers_temp" "$sudoers_target" || exit 1
    chmod 440 "$sudoers_target" || exit 1
    sudoers_summary=changed
fi

if install_executable "$script_dir/notch-sleepguard" "$install_bin/notch-sleepguard"; then
    sleepguard_summary=changed
fi
if install_executable "$script_dir/notch-sleepguard-watchdog" "$install_bin/notch-sleepguard-watchdog"; then
    watchdog_summary=changed
fi
set_invoking_owner "$install_prefix" "$install_bin" "$install_bin/notch-sleepguard" "$install_bin/notch-sleepguard-watchdog"

plist_temp=$launchagents_dir/.notch-hud-sleepguard.$$.plist
{
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0"><dict>'
    printf '%s\n' '  <key>Label</key><string>com.actionable.notchhud.sleepguard</string>'
    printf '  <key>ProgramArguments</key><array><string>%s/notch-sleepguard-watchdog</string></array>\n' "$install_bin"
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

if [ -n "${NOTCH_AN_LAUNCHCTL:-}" ]; then
    if "$NOTCH_AN_LAUNCHCTL" bootstrap "gui/$invoking_uid" "$plist_target" >/dev/null 2>&1; then
        launchctl_summary=changed
    fi
elif [ -z "${NOTCH_AN_PREFIX:-}${NOTCH_AN_LAUNCHAGENTS_DIR:-}${NOTCH_AN_SUDOERS_DIR:-}" ]; then
    if /bin/launchctl bootstrap "gui/$invoking_uid" "$plist_target" >/dev/null 2>&1; then
        launchctl_summary=changed
    fi
fi

printf '%s\n' 'All-Nighter install summary:'
printf '  sudoers: %s\n' "$sudoers_summary"
printf '  notch-sleepguard: %s\n' "$sleepguard_summary"
printf '  watchdog: %s\n' "$watchdog_summary"
printf '  LaunchAgent plist: %s\n' "$plist_summary"
printf '  launchctl bootstrap: %s\n' "$launchctl_summary"

exit 0
