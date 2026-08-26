#!/bin/sh

script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
install_prefix=${VIBENOTCH_INSTALL_PREFIX:-"$HOME/.vibenotch"}
install_bin=$install_prefix/bin
codex_config=${VIBENOTCH_CODEX_CONFIG:-"$HOME/.codex/config.toml"}
zshrc=$HOME/.zshrc
timestamp=$(date -u +%Y%m%d%H%M%S)

bin_summary=skipped
config_summary=skipped
path_summary=skipped

warn() {
    printf '%s\n' "vibenotch: warning: $*" >&2
}

# Keep this filter in sync with scripts/vibenotch-codex-notify.  It removes
# only callbacks which lead back to a Vibenotch notifier; the surrounding
# notifier (for example Codex Computer Use) remains enabled.
sanitize_notify_command() {
    jq -ce --arg target "$notify_target" '
        def is_vibenotch($target):
            type == "string"
            and (
                . == $target
                or endswith("/vibenotch-codex-notify")
                or endswith("/notch-codex-notify")
            );

        def mentions_vibenotch_executable:
            type == "string"
            and (
                contains("vibenotch-codex-notify")
                or contains("notch-codex-notify")
            );

        def decoded_command:
            if type == "array" then .
            elif type == "string" then (try fromjson catch null)
            else null
            end;

        def valid_command:
            type == "array"
            and length > 0
            and all(.[]; type == "string")
            and .[0] != "";

        def is_shell:
            type == "string"
            and test("(^|/)(ba|z|da|k)?sh$");

        def directly_calls_vibenotch($target):
            (length > 0 and (.[0] | is_vibenotch($target)))
            or (
                length > 1
                and (.[0] | is_shell)
                and (.[1] | is_vibenotch($target))
            )
            or (
                length > 1
                and (.[0] | type == "string")
                and (.[0] | test("(^|/)env$"))
                # env has options with and without operands. Conservatively
                # reject explicit paths and split-string/variable operands
                # which mention the executable after this known launcher.
                and any(.[1:][];
                    is_vibenotch($target) or mentions_vibenotch_executable
                )
            );

        def sanitize_command($target; $depth):
            if $depth >= 16 then []
            elif (valid_command | not) then []
            elif directly_calls_vibenotch($target) then
                if (.[0] | is_vibenotch($target)) then
                    # Compatibility with the pre-rename array format, where a
                    # second notifier could follow our old executable.
                    map(select((is_vibenotch($target)) | not))
                    | sanitize_command($target; $depth + 1)
                else []
                end
            else . as $command
            | reduce range(0; $command | length) as $index (
                {output: [], skip_until: 0};
                if $index < .skip_until then .
                elif $command[$index] == "--previous-notify"
                     and ($index + 1) < ($command | length)
                then ($command[$index + 1] | decoded_command) as $nested
                | if ($nested | valid_command) then
                    ($nested | sanitize_command($target; $depth + 1)) as $clean
                    | if ($clean | length) == 0 then
                        .skip_until = ($index + 2)
                      elif $clean == $nested then
                        .output += ["--previous-notify", $command[$index + 1]]
                        | .skip_until = ($index + 2)
                      else
                        .output += ["--previous-notify", ($clean | tojson)]
                        | .skip_until = ($index + 2)
                      end
                  else .output += [$command[$index]]
                  end
                elif ($command[$index] | startswith("--previous-notify="))
                then (
                    $command[$index]
                    | ltrimstr("--previous-notify=")
                    | decoded_command
                ) as $nested
                | if ($nested | valid_command) then
                    ($nested | sanitize_command($target; $depth + 1)) as $clean
                    | if ($clean | length) == 0 then .
                      elif $clean == $nested then .output += [$command[$index]]
                      else .output += ["--previous-notify=" + ($clean | tojson)]
                      end
                  else .output += [$command[$index]]
                  end
                else .output += [$command[$index]]
                end
            )
            | .output
            end;

        if type != "array"
           or length == 0
           or (all(.[]; type == "string") | not)
           or .[0] == ""
        then error("invalid notify command")
        else sanitize_command($target; 0)
        end
    '
}

chain_file=$install_prefix/codex-notify-chain.json

write_chain_atomic() {
    chain_json=$1
    chain_temporary=$chain_file.tmp.$$
    if ! (umask 077 && printf '%s\n' "$chain_json" > "$chain_temporary"); then
        rm -f "$chain_temporary"
        return 1
    fi
    if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
        "$chain_temporary" >/dev/null 2>&1
    then
        rm -f "$chain_temporary"
        return 1
    fi
    if ! mv -f "$chain_temporary" "$chain_file"; then
        rm -f "$chain_temporary"
        return 1
    fi
}

remove_chain() {
    if [ -f "$chain_file" ]; then
        rm -f "$chain_file" || exit 1
        config_summary=changed
    fi
}

reconcile_saved_chain() {
    [ -f "$chain_file" ] || return 0

    original_compact=$(jq -c . "$chain_file" 2>/dev/null) || original_compact=
    sanitized=$(sanitize_notify_command < "$chain_file" 2>/dev/null) || sanitized=
    if [ -z "$sanitized" ] || [ "$sanitized" = "[]" ]; then
        remove_chain
        warn "removed an invalid or circular Codex notify chain from $chain_file"
        return 0
    fi
    if [ "$sanitized" != "$original_compact" ]; then
        write_chain_atomic "$sanitized" || exit 1
        config_summary=changed
        warn "removed a circular --previous-notify callback from $chain_file"
    fi
}

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

if install_file "$script_dir/vibenotch-emit" "$install_bin/vibenotch-emit"; then
    bin_summary=changed
fi
if install_file "$script_dir/vibenotch-codex-notify" "$install_bin/vibenotch-codex-notify"; then
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
notify_target=$install_bin/vibenotch-codex-notify

# Reconcile on every install/update, including when Codex already points at
# Vibenotch. This migrates installations affected by the old circular chain.
reconcile_saved_chain

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
            original_notify_compact=$(printf '%s\n' "$notify_value" | jq -c .) || exit 1
            chain_value=$(printf '%s\n' "$notify_value" | sanitize_notify_command) || exit 1
            if [ "$chain_value" = "[]" ]; then
                remove_chain
                warn "removed a Codex notify command which called Vibenotch recursively"
            else
                write_chain_atomic "$chain_value" || exit 1
                if [ "$chain_value" != "$original_notify_compact" ]; then
                    warn "removed a circular --previous-notify callback while preserving the previous notifier"
                fi
            fi
        else
            # Refuse loudly rather than silently dropping an existing notify
            # command we cannot parse (single-quoted TOML, trailing comment,
            # multiline array...).
            printf '%s\n' "vibenotch: existing notify has an unsupported format; not touching $codex_config" >&2
            printf '%s\n' "  value: $notify_value" >&2
            rm -f "$codex_config.bak.$timestamp"
            exit 1
        fi
    else
        remove_chain
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

marker='# vibenotch codex shim'
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
