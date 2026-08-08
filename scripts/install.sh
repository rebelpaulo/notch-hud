#!/bin/sh

# Installs Vibenotch from a local checkout: builds from source (no code
# signing / notarization needed this way), bundles the .app, installs it to
# /Applications, installs the runtime scripts to ~/.vibenotch/bin, and wires
# the Claude Code + Codex CLI adapters. Idempotent — safe to re-run.
#
# Usage: scripts/install.sh [--yes] [--skip-claude-hooks] [--skip-codex] [--uninstall]
#
# Env overrides (mainly for tests / dry-runs — never needed for a normal
# install):
#   VIBENOTCH_INSTALL_PREFIX       default $HOME/.vibenotch
#   VIBENOTCH_INSTALL_CLAUDE_SETTINGS  default $HOME/.claude/settings.json
#   VIBENOTCH_INSTALL_APPLICATIONS_DIR default /Applications
#   VIBENOTCH_INSTALL_MAKE_APP         default $script_dir/make-app.sh (build step)
#   VIBENOTCH_INSTALL_OPEN             default `open` (launch step)

set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd) || exit 1
repo_root=$(CDPATH= cd -P "$script_dir/.." 2>/dev/null && pwd) || exit 1

assume_yes=0
skip_claude_hooks=0
skip_codex=0
do_uninstall=0

for arg in "$@"; do
    case $arg in
        --yes) assume_yes=1 ;;
        --skip-claude-hooks) skip_claude_hooks=1 ;;
        --skip-codex) skip_codex=1 ;;
        --uninstall) do_uninstall=1 ;;
        --help|-h)
            cat <<'USAGE'
usage: scripts/install.sh [--yes] [--skip-claude-hooks] [--skip-codex] [--uninstall]

  --yes                 answer yes to every prompt
  --skip-claude-hooks   leave ~/.claude/settings.json alone
  --skip-codex          leave the Codex CLI adapter alone
  --uninstall           remove what this installer installed
USAGE
            exit 0
            ;;
        *)
            printf '%s\n' "vibenotch: unknown option: $arg (see --help)" >&2
            exit 64
            ;;
    esac
done

notch_home=${VIBENOTCH_INSTALL_PREFIX:-"$HOME/.vibenotch"}
install_bin=$notch_home/bin
applications_dir=${VIBENOTCH_INSTALL_APPLICATIONS_DIR:-/Applications}
app_target=$applications_dir/Vibenotch.app

# --- uninstall -------------------------------------------------------------

run_uninstall() {
    printf '%s\n' "Uninstalling Vibenotch..."

    bin_summary=skipped
    if [ -d "$install_bin" ]; then
        rm -rf "$install_bin" || exit 1
        bin_summary=removido
    fi

    hooks_summary=ignorado
    if [ "$skip_claude_hooks" -eq 0 ]; then
        VIBENOTCH_INSTALL_PREFIX=$notch_home "$script_dir/install-claude-hooks.sh" --uninstall
        hooks_summary="ver acima"
    fi

    app_summary=skipped
    if [ -d "$app_target" ]; then
        rm -rf "$app_target" || exit 1
        app_summary=removida
    fi

    cat <<SUMMARY

Uninstall summary:
  binaries ($install_bin): $bin_summary
  Claude Code hooks: $hooks_summary
  app ($app_target): $app_summary

NOT touched (remove by hand if you want them gone):
  - the Gotta go! sudoers rule (/etc/sudoers.d/vibenotch)
  - the watchdog LaunchAgent (~/Library/LaunchAgents/com.rebelpaulo.vibenotch.sleepguard.plist)
  - the phone pairing file (~/.vibenotch/remote.json)

Note: the PATH line in ~/.zshrc and the "notify" entry in ~/.codex/config.toml
added by the Codex adapter are also left as they are — edit them by hand to
revert (scripts/install-codex-adapter.sh has no uninstall mode).
SUMMARY
    exit 0
}

[ "$do_uninstall" -eq 1 ] && run_uninstall

# --- preflight ---------------------------------------------------------

preflight() {
    printf '%s\n' "A verificar requisitos..."

    macos_version=$(sw_vers -productVersion 2>/dev/null || printf '')
    macos_major=${macos_version%%.*}
    case $macos_major in
        ''|*[!0-9]*)
            printf '%s\n' "vibenotch: could not determine the macOS version." >&2
            exit 1
            ;;
    esac
    if [ "$macos_major" -lt 14 ]; then
        printf '%s\n' "vibenotch: é necessário macOS 14 ou superior (detetado: $macos_version)." >&2
        exit 1
    fi

    if ! xcode-select -p >/dev/null 2>&1; then
        printf '%s\n' "vibenotch: Xcode Command Line Tools are missing. Run 'xcode-select --install' and try again." >&2
        exit 1
    fi

    if ! command -v swift >/dev/null 2>&1; then
        printf '%s\n' "vibenotch: 'swift' not found (check the Command Line Tools)." >&2
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "vibenotch: 'jq' is missing. Run 'brew install jq' and try again." >&2
        exit 1
    fi

    # ponytail: best-effort model allowlist, not a real notch probe (macOS
    # exposes no such API) — false negatives just print a warning, never
    # block install, since the app already falls back to a floating pill.
    model=$(sysctl -n hw.model 2>/dev/null || printf '')
    case $model in
        MacBookPro18,*|Mac14,5|Mac14,6|Mac14,7|Mac14,9|Mac14,10|Mac14,15|Mac15,*)
            ;;
        *)
            printf '%s\n' "warning: could not confirm this Mac has a notch (model: ${model:-unknown}) — the app falls back to a floating pill." >&2
            ;;
    esac

    printf '%s\n' "Requisitos OK."
}

# --- build + bundle ------------------------------------------------------

build_and_bundle() {
    printf '%s\n' "A compilar (swift build -c release via scripts/make-app.sh)... isto pode demorar."
    "${VIBENOTCH_INSTALL_MAKE_APP:-"$script_dir/make-app.sh"}"
}

install_app_bundle() {
    app_source=$repo_root/build/Vibenotch.app
    [ -d "$app_source" ] || {
        printf '%s\n' "vibenotch: build/Vibenotch.app was not created." >&2
        exit 1
    }

    mkdir -p "$applications_dir" || exit 1

    if [ -d "$app_target" ]; then
        if [ "$assume_yes" -eq 0 ]; then
            if [ -t 0 ]; then
                printf '%s' "Vibenotch.app already exists in $applications_dir. Replace it? [y/N] "
                read -r reply
                case $reply in
                    [sSyY]|[sSyY][iIeE][mMsS]) ;;
                    *)
                        printf '%s\n' "Keeping the existing app."
                        return 0
                        ;;
                esac
            else
                printf '%s\n' "vibenotch: $app_target already exists; run with --yes to replace it without asking." >&2
                exit 1
            fi
        fi
        rm -rf "$app_target" || exit 1
    fi

    cp -R "$app_source" "$app_target" || exit 1
    printf '%s\n' "App installed at $app_target"
}

launch_app() {
    if [ -d "$app_target" ]; then
        "${VIBENOTCH_INSTALL_OPEN:-open}" "$app_target" >/dev/null 2>&1 || printf '%s\n' "warning: could not open the app automatically; open $app_target yourself." >&2
    fi
}

# --- runtime scripts -------------------------------------------------------

install_runtime_scripts() {
    mkdir -p "$install_bin" || exit 1
    for name in vibenotch-emit vibenotch-claude-hook vibenotch-codex-notify vibenotch-sleepguard vibenotch-sleepguard-watchdog vibenotch-remote-push; do
        cp "$script_dir/$name" "$install_bin/$name" || exit 1
        chmod +x "$install_bin/$name" || exit 1
    done
    cp "$script_dir/codex-shim" "$install_bin/codex" || exit 1
    chmod +x "$install_bin/codex" || exit 1
    printf '%s\n' "Scripts installed in $install_bin"
}

install_claude_hooks_step() {
    if [ "$skip_claude_hooks" -eq 1 ]; then
        printf '%s\n' "Claude Code hooks: skipped (--skip-claude-hooks)"
        return 0
    fi
    VIBENOTCH_INSTALL_PREFIX=$notch_home "$script_dir/install-claude-hooks.sh"
}

install_codex_step() {
    if [ "$skip_codex" -eq 1 ]; then
        printf '%s\n' "Adaptador Codex: ignorado (--skip-codex)"
        return 0
    fi
    VIBENOTCH_INSTALL_PREFIX=$notch_home "$script_dir/install-codex-adapter.sh"
}

# --- main --------------------------------------------------------------

preflight
build_and_bundle
install_app_bundle
launch_app
install_runtime_scripts
install_claude_hooks_step
install_codex_step

claude_hooks_summary=$([ "$skip_claude_hooks" -eq 1 ] && printf 'skipped' || printf 'see above')
codex_summary=$([ "$skip_codex" -eq 1 ] && printf 'skipped' || printf 'see above')

cat <<SUMMARY

Vibenotch installed.
  App:                 $app_target
  Scripts:             $install_bin
  Claude Code hooks:   $claude_hooks_summary
  Codex adapter:       $codex_summary

Optional next steps:
  - Gotta go! (keep the Mac awake with the lid closed; needs sudo):
      sudo scripts/install-gotta-go.sh
  - Phone companion: see the README ("Phone companion") for the notch-remote
    repository and the pairing steps.
SUMMARY
