#!/bin/sh

# Installs NotchHUD from a local checkout: builds from source (no code
# signing / notarization needed this way), bundles the .app, installs it to
# /Applications, installs the runtime scripts to ~/.notch-hud/bin, and wires
# the Claude Code + Codex CLI adapters. Idempotent — safe to re-run.
#
# Usage: scripts/install.sh [--yes] [--skip-claude-hooks] [--skip-codex] [--uninstall]
#
# Env overrides (mainly for tests / dry-runs — never needed for a normal
# install):
#   NOTCH_HUD_INSTALL_PREFIX       default $HOME/.notch-hud
#   NOTCH_INSTALL_CLAUDE_SETTINGS  default $HOME/.claude/settings.json
#   NOTCH_INSTALL_APPLICATIONS_DIR default /Applications
#   NOTCH_INSTALL_MAKE_APP         default $script_dir/make-app.sh (build step)
#   NOTCH_INSTALL_OPEN             default `open` (launch step)

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
uso: scripts/install.sh [--yes] [--skip-claude-hooks] [--skip-codex] [--uninstall]

  --yes                 não pergunta nada (assume "sim" a tudo)
  --skip-claude-hooks   não mexe em ~/.claude/settings.json
  --skip-codex          não mexe no adaptador do Codex CLI
  --uninstall           remove o que este instalador instalou
USAGE
            exit 0
            ;;
        *)
            printf '%s\n' "notch-hud: opção desconhecida: $arg (usa --help)" >&2
            exit 64
            ;;
    esac
done

notch_home=${NOTCH_HUD_INSTALL_PREFIX:-"$HOME/.notch-hud"}
install_bin=$notch_home/bin
applications_dir=${NOTCH_INSTALL_APPLICATIONS_DIR:-/Applications}
app_target=$applications_dir/NotchHUD.app

# --- uninstall -------------------------------------------------------------

run_uninstall() {
    printf '%s\n' "A desinstalar o NotchHUD..."

    bin_summary=skipped
    if [ -d "$install_bin" ]; then
        rm -rf "$install_bin" || exit 1
        bin_summary=removido
    fi

    hooks_summary=ignorado
    if [ "$skip_claude_hooks" -eq 0 ]; then
        NOTCH_HUD_INSTALL_PREFIX=$notch_home "$script_dir/install-claude-hooks.sh" --uninstall
        hooks_summary="ver acima"
    fi

    app_summary=skipped
    if [ -d "$app_target" ]; then
        rm -rf "$app_target" || exit 1
        app_summary=removida
    fi

    cat <<SUMMARY

Resumo da desinstalação:
  binários ($install_bin): $bin_summary
  hooks do Claude Code: $hooks_summary
  aplicação ($app_target): $app_summary

NÃO foi tocado (remove à mão se quiseres):
  - regra sudoers do All-Nighter (/etc/sudoers.d/notch-hud)
  - LaunchAgent do watchdog (~/Library/LaunchAgents/com.actionable.notchhud.sleepguard.plist)
  - ficheiro de emparelhamento do telemóvel (~/.notch-hud/remote.json)

Nota: a linha de PATH no ~/.zshrc e a entrada "notify" no ~/.codex/config.toml
adicionadas pelo adaptador Codex também ficam como estão — edita-as à mão se
quiseres reverter (scripts/install-codex-adapter.sh não tem um modo de remoção).
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
            printf '%s\n' "notch-hud: não foi possível determinar a versão do macOS." >&2
            exit 1
            ;;
    esac
    if [ "$macos_major" -lt 14 ]; then
        printf '%s\n' "notch-hud: é necessário macOS 14 ou superior (detetado: $macos_version)." >&2
        exit 1
    fi

    if ! xcode-select -p >/dev/null 2>&1; then
        printf '%s\n' "notch-hud: Xcode Command Line Tools em falta. Corre 'xcode-select --install' e tenta de novo." >&2
        exit 1
    fi

    if ! command -v swift >/dev/null 2>&1; then
        printf '%s\n' "notch-hud: comando 'swift' não encontrado (verifica as Command Line Tools)." >&2
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "notch-hud: 'jq' em falta. Corre 'brew install jq' e tenta de novo." >&2
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
            printf '%s\n' "aviso: não foi possível confirmar que este Mac tem notch (modelo: ${model:-desconhecido}) — a app usa uma pill flutuante como alternativa." >&2
            ;;
    esac

    printf '%s\n' "Requisitos OK."
}

# --- build + bundle ------------------------------------------------------

build_and_bundle() {
    printf '%s\n' "A compilar (swift build -c release via scripts/make-app.sh)... isto pode demorar."
    "${NOTCH_INSTALL_MAKE_APP:-"$script_dir/make-app.sh"}"
}

install_app_bundle() {
    app_source=$repo_root/build/NotchHUD.app
    [ -d "$app_source" ] || {
        printf '%s\n' "notch-hud: build/NotchHUD.app não foi criado." >&2
        exit 1
    }

    mkdir -p "$applications_dir" || exit 1

    if [ -d "$app_target" ]; then
        if [ "$assume_yes" -eq 0 ]; then
            if [ -t 0 ]; then
                printf '%s' "Já existe uma NotchHUD.app em $applications_dir. Substituir? [s/N] "
                read -r reply
                case $reply in
                    [sSyY]|[sSyY][iIeE][mMsS]) ;;
                    *)
                        printf '%s\n' "A manter a aplicação existente."
                        return 0
                        ;;
                esac
            else
                printf '%s\n' "notch-hud: já existe $app_target; corre com --yes para substituir sem perguntar." >&2
                exit 1
            fi
        fi
        rm -rf "$app_target" || exit 1
    fi

    cp -R "$app_source" "$app_target" || exit 1
    printf '%s\n' "Aplicação instalada em $app_target"
}

launch_app() {
    if [ -d "$app_target" ]; then
        "${NOTCH_INSTALL_OPEN:-open}" "$app_target" >/dev/null 2>&1 || printf '%s\n' "aviso: não foi possível abrir a aplicação automaticamente; abre $app_target manualmente." >&2
    fi
}

# --- runtime scripts -------------------------------------------------------

install_runtime_scripts() {
    mkdir -p "$install_bin" || exit 1
    for name in notch-emit notch-claude-hook notch-codex-notify notch-sleepguard notch-sleepguard-watchdog notch-remote-push; do
        cp "$script_dir/$name" "$install_bin/$name" || exit 1
        chmod +x "$install_bin/$name" || exit 1
    done
    cp "$script_dir/codex-shim" "$install_bin/codex" || exit 1
    chmod +x "$install_bin/codex" || exit 1
    printf '%s\n' "Scripts instalados em $install_bin"
}

install_claude_hooks_step() {
    if [ "$skip_claude_hooks" -eq 1 ]; then
        printf '%s\n' "Hooks do Claude Code: ignorado (--skip-claude-hooks)"
        return 0
    fi
    NOTCH_HUD_INSTALL_PREFIX=$notch_home "$script_dir/install-claude-hooks.sh"
}

install_codex_step() {
    if [ "$skip_codex" -eq 1 ]; then
        printf '%s\n' "Adaptador Codex: ignorado (--skip-codex)"
        return 0
    fi
    NOTCH_HUD_INSTALL_PREFIX=$notch_home "$script_dir/install-codex-adapter.sh"
}

# --- main --------------------------------------------------------------

preflight
build_and_bundle
install_app_bundle
launch_app
install_runtime_scripts
install_claude_hooks_step
install_codex_step

claude_hooks_summary=$([ "$skip_claude_hooks" -eq 1 ] && printf 'ignorado' || printf 'ver acima')
codex_summary=$([ "$skip_codex" -eq 1 ] && printf 'ignorado' || printf 'ver acima')

cat <<SUMMARY

NotchHUD instalado.
  Aplicação:            $app_target
  Scripts:               $install_bin
  Hooks do Claude Code:   $claude_hooks_summary
  Adaptador Codex:        $codex_summary

Passos opcionais:
  - All-Nighter (manter o Mac acordado com a tampa fechada; precisa de sudo):
      sudo scripts/install-all-nighter.sh
  - Companion no telemóvel: consulta o README (secção "Phone companion") para
    o repositório notch-remote e o processo de emparelhamento.
SUMMARY
