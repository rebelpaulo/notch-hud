# Vibenotch

A live HUD for your AI coding agents, parked in the MacBook notch.

Vibenotch watches your Claude Code and Codex CLI sessions and shows their
status — **Working**, **Needs me**, **Done** — right where you're already
looking. Hover the notch to expand a glass panel with every session, click a
row to jump straight to its terminal tab, and (for Claude Code) act on
permission prompts inline without leaving the notch. An optional
**All-Nighter** mode keeps the Mac awake even with the lid closed while
agents are running, and an optional phone companion pushes notifications to
your phone when a session needs you.

Built with Swift 6 / SwiftUI + AppKit, Swift Package Manager, Command Line
Tools only (no Xcode project, no code signing, no notarization needed for a
from-source build). See `TASKS.md` for build state and `specs/` for
milestone specs.

The app UI itself is in Portuguese (PT-PT); this README is in English.

## Screenshots

The repo root has a handful of PNGs captured during development
(`expanded.png`, `m3b_full.png`, `m4_pop.png`, …) that show the panel at
various milestones. There isn't yet a curated, up-to-date "here's what it
looks like today" screenshot — if you want one, run the app and drop a fresh
capture in `assets/` (or replace this section with an `![](path)` once you
have one you're happy with).

## What it is

- Live status pill in the notch (or a floating pill on notch-less Macs) for
  every Claude Code and Codex session you have running in a terminal
- Hover to expand a glass panel listing all sessions with project, current
  task/tool, and status
- Click a session to raise the exact terminal tab it's running in
  (Terminal.app today; iTerm2/WezTerm/Kitty strategies exist as stubs)
- Inline permission approvals for Claude Code tool calls, with diff-style
  detail, when explicitly enabled (see [Security](#security) — this is
  opt-in and not wired up by the base installer)
- **All-Nighter**: keeps the Mac from sleeping while agents are working, even
  with the lid closed, via a narrowly-scoped `sudo` rule (optional, separate
  install step)
- Phone companion: push notifications to your phone when a session needs you
  or the battery is getting low during an All-Nighter run (optional, separate repo)

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)
- `jq` (`brew install jq`)
- A notch is not required — the app falls back to a floating pill on Macs
  without one

## Install

```sh
git clone https://github.com/rebelpaulo/vibenotch.git
cd vibenotch
./scripts/install.sh
```

This builds Vibenotch from source and installs it — no signing or
notarization needed because you're building it yourself. The installer is
idempotent (safe to re-run) and only touches your files additively, with a
timestamped `.bak` before it changes anything that isn't its own.

Flags:

| Flag | Effect |
|---|---|
| `--yes` | Don't prompt for anything (e.g. overwriting an existing `/Applications/Vibenotch.app`) |
| `--skip-claude-hooks` | Don't touch `~/.claude/settings.json` |
| `--skip-codex` | Don't touch `~/.codex/config.toml` or `~/.zshrc` |
| `--uninstall` | Remove what the installer installed (see [Uninstall](#uninstall)) |

If you'd rather do it by hand, or only want part of it:

```sh
swift build -c release          # compile
scripts/make-app.sh              # produce build/Vibenotch.app (ad-hoc signed)
cp -R build/Vibenotch.app /Applications/
open /Applications/Vibenotch.app
```

then install the runtime scripts and hooks yourself — see the next section
for exactly what `install.sh` does, so you can replicate whichever parts you
want.

## What it installs, and where

Everything lives under `~/.vibenotch/` except the app itself:

| What | Where | Notes |
|---|---|---|
| The app | `/Applications/Vibenotch.app` | Ad-hoc signed by `scripts/make-app.sh`; asks before overwriting an existing copy unless `--yes` |
| Runtime scripts | `~/.vibenotch/bin/` | `vibenotch-emit`, `vibenotch-claude-hook`, `vibenotch-codex-notify`, `vibenotch-sleepguard`, `vibenotch-sleepguard-watchdog`, `vibenotch-remote-push`, and `codex-shim` installed as `codex` |
| Session spool | `~/.vibenotch/sessions/*.json` | Written at runtime by the hooks below — one file per live session |

Files it **modifies** (each with a timestamped `.bak` made first, and only
if a change is actually needed):

- **`~/.claude/settings.json`** — adds five hook entries, all calling
  `~/.vibenotch/bin/vibenotch-claude-hook`:
  `UserPromptSubmit`→`working`, `PreToolUse` (matcher `*`)→`tool`,
  `Stop`→`done`, `Notification`→`notify`, `SessionEnd`→`remove`. This is
  purely additive: it detects its own entries by the `vibenotch-claude-hook`
  path and never removes or rewrites hooks it didn't add (your `rtk hook
  claude` PreToolUse entry, for instance, is left exactly as-is). Re-running
  the installer is a no-op once these are in place. Skip this step with
  `--skip-claude-hooks`.
- **`~/.codex/config.toml`** — sets `notify = ["~/.vibenotch/bin/vibenotch-codex-notify"]`.
  If you already had a `notify` command configured (e.g. Codex's own
  computer-use client), it's preserved and chained: Vibenotch's notify runs
  first, then yours. Skip this with `--skip-codex`.
- **`~/.zshrc`** — appends a line putting `~/.vibenotch/bin` on your `PATH`
  ahead of the system one, so the installed `codex` shim (which wraps the
  real `codex` binary to report status, then execs it) is what actually
  runs. Also skipped by `--skip-codex`.

The Claude-hook merge and the Codex adapter wiring are separate, idempotent
scripts (`scripts/install-claude-hooks.sh`, `scripts/install-codex-adapter.sh`)
that `scripts/install.sh` calls — you can run either on its own.

## Optional: All-Nighter (keep-awake with the lid closed)

Off by default; a separate, `sudo`-gated step:

```sh
sudo scripts/install-gotta-go.sh
```

This installs, each idempotently and with a `.bak` of anything it replaces:

- **A sudoers rule** at `/etc/sudoers.d/vibenotch`, validated with `visudo
  -c` before it's ever activated (the installer refuses to install anything
  that doesn't pass validation). Its scope is exactly two commands and
  nothing else:
  ```text
  <you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
  ```
  That's the entire grant — it lets Vibenotch flip macOS's `disablesleep`
  flag on and off without a password prompt each time. It cannot run any
  other command as root.
- **`vibenotch-sleepguard`** (`~/.vibenotch/bin/vibenotch-sleepguard`) — a thin
  wrapper around `sudo -n pmset -a disablesleep {1,0}` (reads of `pmset -g`
  status never go through `sudo`, since the rule above doesn't cover reads).
- **A watchdog LaunchAgent**
  (`~/Library/LaunchAgents/com.rebelpaulo.vibenotch.sleepguard.plist`),
  running every 60 seconds via `vibenotch-sleepguard-watchdog`. If Vibenotch.app
  isn't running (crashed, force-quit, whatever) it turns `disablesleep` back
  off — a fail-safe so a dead app can't accidentally keep your Mac awake
  forever.

## Optional: phone companion

Vibenotch can push a notification to your phone when a session needs you, or
when the battery drops during an All-Nighter run. The Mac side is just
`~/.vibenotch/bin/vibenotch-remote-push`, which reads a pairing file at
`~/.vibenotch/remote.json` (`{"url": "...", "secret": "..."}`) and POSTs to
that URL with a bearer token — this repo doesn't create that file or that
backend for you.

The receiving side lives in a separate repo, **notch-remote**: a small
Vercel-hosted web app that Supabase backs for pairing/session state, using
Web Push (VAPID keys) to deliver notifications to your phone's browser
without needing an app-store install. Pairing it writes
`~/.vibenotch/remote.json` on this Mac; see that repo for its own setup
instructions (Supabase project + Vercel deploy + VAPID key generation).

## Uninstall

```sh
./scripts/install.sh --uninstall
```

Removes:

- `~/.vibenotch/bin/` (all the runtime scripts)
- The five hook entries from `~/.claude/settings.json` (only the entries
  whose command points at `vibenotch-claude-hook` — everything else in that file
  is left alone), unless `--skip-claude-hooks` was also passed
- `/Applications/Vibenotch.app`

It deliberately does **not** touch:

- The All-Nighter sudoers rule (`/etc/sudoers.d/vibenotch`) — remove with
  `sudo rm /etc/sudoers.d/vibenotch`
- The watchdog LaunchAgent
  (`~/Library/LaunchAgents/com.rebelpaulo.vibenotch.sleepguard.plist`) — `sudo
  launchctl bootout gui/$(id -u) <path>` then remove the file
- Your phone-pairing file (`~/.vibenotch/remote.json`)
- The `notify` line in `~/.codex/config.toml` and the `PATH` line in
  `~/.zshrc` added by the Codex adapter — `scripts/install-codex-adapter.sh`
  has no uninstall mode, so edit these by hand if you want them gone

## Troubleshooting

- **No sessions showing up.** Either the hooks aren't installed
  (`grep vibenotch-claude-hook ~/.claude/settings.json`), or your terminal was
  already open when you ran the installer — the `PATH` change for the Codex
  shim only takes effect in new shells, so restart your terminal (or `source
  ~/.zshrc`).
- **Codex Desktop app sessions.** The `codex` shim only covers CLI usage.
  Desktop-app sessions are picked up separately via `vibenotch-codex-notify`
  when the app's own notify hook fires (client `"Codex Desktop"`), keyed by
  a truncated conversation ID — CLI and desktop sessions won't collide.
- **Click-to-focus doesn't raise the right terminal tab.** The first click
  triggers a macOS Automation permission prompt (System Settings → Privacy &
  Security → Automation → Vibenotch → Terminal). Grant it; if you dismissed
  the prompt, re-enable it there manually.
- **All-Nighter says it's off but the Mac still won't sleep, or vice
  versa.** Check `pmset -g | grep SleepDisabled` — the watchdog LaunchAgent
  should force this back off within 60 seconds of Vibenotch.app not running;
  if it doesn't, check `pmset -g` works without a password prompt
  (that's what the sudoers rule grants).

## Security

- Everything Vibenotch runs as your own user: the shell hooks
  (`vibenotch-claude-hook`, `vibenotch-codex-notify`, the `codex` shim) just read
  small JSON payloads from Claude Code/Codex and write JSON files to
  `~/.vibenotch/sessions/`. None of that needs elevated privileges.
- The **only** thing that ever runs with `sudo` is the optional All-Nighter
  step, and its sudoers grant is scoped to exactly two `pmset`
  sub-commands (see [above](#optional-all-nighter-keep-awake-with-the-lid-closed)) —
  it cannot be used to run arbitrary commands as root.
- Data stored locally, all under `~/.vibenotch/`: session status JSON
  (`sessions/*.json` — project name, cwd, current task/tool text, terminal
  tty), your phone-pairing URL and secret if you set one up
  (`remote.json`), and, if you enable inline approvals, pending/decision
  files for tool calls awaiting your OK. None of it leaves the machine
  except the phone-companion push, which you opt into and point at your own
  backend.
