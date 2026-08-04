# NotchHUD — Build Task List

Source of truth for the `/goal` autonomous loop. A task is checked off ONLY when its acceptance check passes (built AND run AND observed). Executor: GPT-5.6 Sol via `codex exec`. Manager: Claude (audits + runs the gate).

Legend: `[ ]` todo · `[~]` in progress · `[x]` verified done

---

## M0 — Notch skeleton
- [x] `Package.swift` (executable `NotchHUD`, macOS 14 target, DynamicNotchKit dependency) — vendored + patched DynamicNotchKit (@Entry/#Preview stripped for CLT)
- [x] App entry: `NotchHUDApp` + `AppDelegate`, `LSUIElement`/`.accessory`, no Dock icon
- [x] `AppEnvironment` (spool path `~/.notch-hud/sessions`, staleness thresholds)
- [x] `NotchWindowManager` wrapping DynamicNotchKit: peek (hardcoded count) + hover-expand static list
- [x] `HoverController` hybrid (tracking window + global mouse monitor, debounced)
- [x] **GATE M0 (build/launch):** `swift build` exits 0; app launches, stays alive, no Dock icon
- [x] **GATE M0 (hover):** widened hitRect covers the visible peek; automated eval `evals/hover_eval.sh` = 4/4 triggers; COOPER CONFIRMED panel drops on hover (2026-07-20)
- [x] M0.5: pure `NotchGeometry` + `swift test` target — 8/8 tests pass (incl. peek-edge regression); hover eval still PASS post-refactor

### Design decisions locked
- **Dark glass** for this app (approved exception to light-theme rule; chin fuses with hardware).
- **Hybrid indicator direction** (2026-07-20): premium glass panel + a subtle reactive mascot accent. Inspiration + differentiation vs Marc Lou's Pac-Man notch (x.com/marclou/status/2079013991834337774): his is Codex-only + 2-state; ours = multi-agent, 3-state (adds "Needs me"), click-to-focus, premium. Mascot needs a distinct working-loop / needs-you / celebratory-done. Detail work lands in M6.

## M1 — One real Claude session end-to-end
- [x] `~/.notch-hud/bin/notch-emit` shared emitter (atomic write, `seq`) — valid JSON verified. NOTE: tty capture returns null, needs fix for M2 click-to-focus
- [x] `notch-claude-hook` shim (stdin JSON → status → notch-emit) — verified with simulated payload (working→done, seq 1→2)
- [x] `Session`, `SessionEnvelope`, `SessionStatus`, `TerminalIdentity` models
- [x] `SpoolWatcher` (DispatchSource vnode + 150ms debounce + rescan-diff), `SpoolReader`, `SessionStore` (@Observable) — watcher verified: 3 fixture sessions rendered live with correct colors + sort (screenshot)
- [x] Views wired to live store (peek count + panel + rows update from spool)
- [x] Add `UserPromptSubmit`→working, `Stop`→done Claude hooks — installed PROJECT-SCOPED (.claude/settings.json in notch-hud) per Cooper, safe test before global
- [x] **GATE M1: COOPER CONFIRMED (2026-07-20)** — real Claude session showed Working (blue) then Done (green)
- [x] Promoted hooks to GLOBAL ~/.claude/settings.json (additive, backup made, all existing hooks preserved) + added SessionEnd→remove for clean lifecycle. Project-scoped copy removed.

## M2 — Click to focus
- [x] `FocusDispatcher` + `FocusStrategy` protocol + strategies (TerminalApp primary, iTerm2/WezTerm/Kitty stubs) — builds, 8/8 tests
- [x] tty ppid-walk fix in notch-emit — verified captures `/dev/ttys012`
- [x] `NSAppleEventsUsageDescription` in Info.plist; rows clickable with grant affordance
- [x] **M2.5: real .app bundle BEFORE TCC grant** — `scripts/make-app.sh`, ad-hoc signed `com.actionable.notchhud`, launched via `open`, hover+watcher verified from bundle (screenshot showed 4 REAL sessions incl. email-triage agent). Initial git commit `fea82f7`.
- [~] **GATE M2 (needs Cooper):** click a live row in the bundled app → Automation prompt (grant it) → correct Terminal tab raises
- Note for M3: headless agents (email-triage etc.) fire hooks too — tag ttyless sessions as background, dim them, exclude from focus

## DESIGN PIVOT 2026-07-21 (Cooper: first design "waaaay off")
North star = Vibe Island (vibeisland.app, @edwardluox). References: `assets/reference/*.jpg` + demo mp4. Match its information design + interaction model with OUR OWN sprite art/identity. Killer missing feature: ACT from the notch (inline permission approvals with diffs). Milestones re-cut below; old M3-M5 superseded.

## M3 — Console redesign + rich live status (spec: specs/M3-console-redesign.md)
- [~] Dispatched to Codex: extended-notch info pill (sprites + mono "Working…" + N sessions), rich cards (project · task / You: prompt / live tool line / agent-model-terminal-elapsed chips), AgentSprite 8×8 own art, emitter merge-preservation, PreToolUse tool-line capture, real-window-frame hover rect
- [ ] Manager: install PreToolUse hook globally (additive) after build gate
- [ ] **GATE M3:** build+tests green; fixture full-card screenshot; real session shows prompt + tool line updating live; Cooper approves the new look

## M4 — Act from the notch (inline approvals) + truthfulness
- [ ] PreToolUse decision bridge (pending-approval file + decision file + ≤55s timeout → terminal fallback)
- [ ] Permission card UI: diff render (red/green), Deny / Allow Once / Bypass, ⌘Y/⌘N
- [ ] Notification hook → needs_me + amber pulse on resting pill; question cards read-only
- [ ] StalenessSweeper (90s demote, 15min drop) + pid reconciliation; ttyless sessions dimmed
- [ ] **GATE M4:** real permission prompt pops the card; Allow Once runs the tool; Deny blocks; timeout falls back; kill -9 demotes ≤90s

## SIDE QUEST 2026-08-04 (Cooper request, via agorch): desktop focus + Codex adapter
- [x] Claude-desktop sessions: ttyless claude* → `source: "claude-desktop"` (notch-emit `--source` flag added); rows clickable with "Desktop" chip; `ClaudeDesktopFocusStrategy` raises via `/usr/bin/open -b` (NSRunningApplication.activate is a silent no-op for background callers under cooperative activation). COOPER CONFIRMED click raises the app. Root-caused: stale tty guard in NotchPanelView → `Session.canFocus` single source of truth.
- [x] Sprite tinted by agent (Claude orange, Codex blue); status keeps driving animation.
- [x] Codex adapter shipped early (see M5 bullet 1): `notch-codex-notify` (done/needs_me, chain-execs prior notify, update-only to prevent post-exit ghost race), `codex` PATH shim (working→remove, exit status preserved, recursion-guarded), idempotent installer with timestamped .baks. Installed on this machine; real `codex exec` verified end-to-end, zero ghosts.

## M5 — Codex adapter + generic poller + usage meters
- [x] `notch-codex-notify` chain-exec wrapper (turn-end → done, SkyComputerUseClient preserved) — delivered 2026-08-04 in the side quest (plus `codex` shim for the working state)
- [ ] `ProcessPoller` (agent regex, source-rank protected, skip ttyless workers)
- [ ] Claude usage meters (5h/7d) in header if a clean local source exists (probe `claude usage` / OAuth)
- [ ] **GATE M5:** Codex working→done with computer-use intact; non-hooked agent appears/clears; meters real or cleanly absent

## M6 — Design polish + productize
- [ ] Liquid Glass material (macOS 26) + NSVisualEffectView fallback; dark-glass panel per art direction
- [ ] Status colors + per-state motion (breathing / blink / checkmark)
- [ ] "The Merge" signature moment (matchedGeometry morph + Vortex burst + count tick + name flash)
- [ ] Pow micro-feedback, Kenney sounds + NSHapticFeedbackManager, SF Pro Rounded, settings window
- [ ] Non-notch fallback pill + multi-monitor re-pin
- [ ] **GATE M6:** on-screen review of all motion moments; final acceptance = 3+ real sessions (2 Claude, 1 Codex), correct peek count, correct states, The Merge fires, click raises correct tab

---
## Completion condition (the `/goal`)
Every box above `[x]`, `swift build` exits 0, the app launches, and each GATE has been confirmed on screen. Stop after the run if all gates green, or halt for a human on any gate that needs visual judgment.
