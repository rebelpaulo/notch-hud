#!/bin/sh

script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
install_prefix=${NOTCH_HUD_INSTALL_PREFIX:-"$HOME/.notch-hud"}
install_bin=$install_prefix/bin
codex_config=${NOTCH_HUD_CODEX_CONFIG:-"$HOME/.codex/config.toml"}
zshrc=$HOME/.zshrc
timestamp=$(date -u +%Y%m%d%H%M%S)

bin_summary=skipped
config_summary=skipped
path_summary=skipped

mkdir -p "$install_bin" || exit 1

install_file() {
    source_file=$1
    target_file=$2
    if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file" && [ -x "$target_file" ]; then
        return 1
    fi
    cp "$source_file" "$target_file" || exit 1
    chmod +x "$target_file" || exit 1
    return 0
}

if install_file "$script_dir/notch-emit" "$install_bin/notch-emit"; then
    bin_summary=changed
fi
if install_file "$script_dir/notch-codex-notify" "$install_bin/notch-codex-notify"; then
    bin_summary=changed
fi
if install_file "$script_dir/codex-shim" "$install_bin/codex"; then
    bin_summary=changed
fi

config_dir=$(dirname "$codex_config")
mkdir -p "$config_dir" || exit 1
[ -f "$codex_config" ] || : > "$codex_config"

notify_line=$(sed -n '/^[[:space:]]*notify[[:space:]]*=/p' "$codex_config" | sed -n '1p')
notify_value=$(printf '%s\n' "$notify_line" | sed 's/^[[:space:]]*notify[[:space:]]*=[[:space:]]*//')
notify_target=$install_bin/notch-codex-notify

already_installed=0
if [ -n "$notify_value" ] && printf '%s\n' "$notify_value" | \
    jq -e --arg target "$notify_target" \
        'type == "array" and length > 0 and .[0] == $target' >/dev/null 2>&1
then
    already_installed=1
fi

if [ "$already_installed" -eq 0 ]; then
    cp "$codex_config" "$codex_config.bak.$timestamp" || exit 1

    if [ -n "$notify_value" ]; then
        if printf '%s\n' "$notify_value" | \
            jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
                >/dev/null 2>&1
        then
            printf '%s\n' "$notify_value" > "$install_prefix/codex-notify-chain.json" || exit 1
        else
            # Refuse loudly rather than silently dropping an existing notify
            # command we cannot parse (single-quoted TOML, trailing comment,
            # multiline array...).
            printf '%s\n' "notch-hud: existing notify has an unsupported format; not touching $codex_config" >&2
            printf '%s\n' "  value: $notify_value" >&2
            rm -f "$codex_config.bak.$timestamp"
            exit 1
        fi
    else
        rm -f "$install_prefix/codex-notify-chain.json" || exit 1
    fi

    notify_json=$(printf '%s' "$notify_target" | jq -Rs .) || exit 1
    replacement="notify = [$notify_json]"
    temporary=$codex_config.tmp.$$
    if [ -n "$notify_line" ]; then
        awk -v replacement="$replacement" '
            BEGIN { replaced = 0 }
            !replaced && /^[[:space:]]*notify[[:space:]]*=/ {
                print replacement
                replaced = 1
                next
            }
            { print }
        ' "$codex_config" > "$temporary" || exit 1
    else
        cp "$codex_config" "$temporary" || exit 1
        if [ -s "$temporary" ]; then
            last_byte=$(tail -c 1 "$temporary" 2>/dev/null | od -An -tu1 | tr -d ' ')
            [ "$last_byte" = 10 ] || printf '\n' >> "$temporary" || exit 1
        fi
        printf '%s\n' "$replacement" >> "$temporary" || exit 1
    fi
    mv "$temporary" "$codex_config" || exit 1
    config_summary=changed
fi

marker='# notch-hud codex shim'
if [ -f "$zshrc" ] && grep -F "$marker" "$zshrc" >/dev/null 2>&1; then
    :
elif [ -f "$zshrc" ] && grep -F "$install_bin" "$zshrc" >/dev/null 2>&1; then
    :
else
    if [ -f "$zshrc" ]; then
        cp "$zshrc" "$zshrc.bak.$timestamp" || exit 1
    fi
    escaped_bin=$(printf '%s' "$install_bin" | sed "s/'/'\\\\''/g")
    {
        [ ! -s "$zshrc" ] || printf '\n'
        printf '%s\n' "$marker"
        printf "export PATH='%s':\"\$PATH\"\n" "$escaped_bin"
    } >> "$zshrc" || exit 1
    path_summary=changed
fi

printf '%s\n' "Codex adapter install summary:"
printf '  bin files: %s\n' "$bin_summary"
printf '  Codex notify config: %s\n' "$config_summary"
printf '  zsh PATH shim: %s\n' "$path_summary"

exit 0
