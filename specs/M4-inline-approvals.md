# M4 spec — Act from the notch: inline permission approvals (for GPT-5.6 Sol)

Reference: `assets/reference/vibeisland-permission-card.jpg` (diff card + Deny / Allow Once / Bypass). Goal: when a Claude session in a terminal needs permission for a write-class tool, the notch pops open a card showing what the tool wants to do (including the diff), and Cooper approves/denies FROM THE NOTCH. The decision flows back via a synchronous PreToolUse hook.

## SAFETY INVARIANTS (violating any of these is a failed implementation)
- The approval hook is **fail-open**: any error, missing file, bad JSON, unexpected state → `exit 0` with NO stdout → Claude's normal permission flow proceeds. Never exit nonzero. Never print anything to stdout except a valid decision JSON.
- Hard timeout **20s** on waiting for a decision; on timeout → no output, normal terminal prompt appears.
- **Never gate background sessions**: if the hook process has no tty ancestor (reuse the `find_tty` ppid-walk from vibenotch-emit) → instant no-op. Cooper's launchd agents (email-triage, CooperBrain) must never stall.
- Feature flag: `~/.vibenotch/config.json` `{"approvals": true}` — if file missing or false → instant no-op. Installer writes it true.
- Only gate when `permission_mode == "default"` and tool ∈ {Edit, Write, NotebookEdit, Bash}. Everything else → instant no-op.

## 1. New hook script `scripts/vibenotch-approve` (POSIX sh + jq, synchronous — NOT async)
Registered as a SECOND PreToolUse hook object (manager installs; timeout 60 in settings).
Flow:
1. Read stdin JSON: `.tool_name`, `.tool_input`, `.session_id`, `.cwd`, `.permission_mode`.
2. Run the no-op checks (flag, tty, mode, tool set). Also: if `~/.vibenotch/session-allow/<session_id>` exists and contains a line matching the tool class (see Bypass below) → output `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Vibenotch bypass"}}` and exit.
3. **Allowlist replication (conservative):** read `permissions.allow` arrays from `~/.claude/settings.json`, `$CLAUDE_PROJECT_DIR/.claude/settings.json`, `$CLAUDE_PROJECT_DIR/.claude/settings.local.json` (each may be absent). Simple matching only: an entry exactly equal to the tool name (e.g. `Edit`, `Write`) allows it; `Bash(<prefix>:*)` or `Bash(<prefix> *)` entries allow Bash commands whose command begins with `<prefix>`. If the call matches an allow entry → instant no-op (Claude will auto-allow; do not gate). When in doubt (weird pattern), treat as NOT allowed and gate — worst case is a 20s-delayed terminal prompt, never a wrong auto-allow. NEVER output "allow" based on this replication — it only decides whether to SKIP gating.
4. Write pending file `~/.vibenotch/pending/<session_id>.json` (atomic tmp+mv):
```json
{ "schema":1, "sessionId":"...", "tool":"Edit", "cwd":"...", "created":"<ISO8601>",
  "summary":"Edit src/auth/middleware.ts",
  "bash": null,
  "edit": {"file":"src/auth/middleware.ts","old":"<old_string>","new":"<new_string>"},
  "write": null }
```
  - Edit → `edit.old/new` (cap each at 4000 chars). Write → `write.file` + first 4000 chars of content. Bash → `bash.command` (full, cap 4000). NotebookEdit → treat like Edit.
5. Poll `~/.vibenotch/decisions/<session_id>.json` every 0.25s up to 20s. On decision `{"decision":"allow"|"deny","scope":"once"|"session"}`:
   - allow → output permissionDecision allow (reason "Approved from Vibenotch"); if scope=session append the tool class line to `~/.vibenotch/session-allow/<session_id>` (`Bash:<first word of command>` or the tool name).
   - deny → output permissionDecision deny (reason "Denied from Vibenotch").
   - Always delete the pending + decision files.
6. Timeout → delete pending file, exit 0 silently.

## 2. App: pending watcher + approval card
- **`PendingStore.swift` + reuse of the watcher:** generalize `SpoolWatcher` (init takes directory + onRescan callback) or add a sibling `PendingWatcher` on `~/.vibenotch/pending/` (create dir in AppEnvironment). Decodes `PendingApproval` model.
- When a pending approval appears: mark that session needs_me in the UI, **auto-expand the panel** (`NotchWindowManager.expand()`), and render `ApprovalCardView` pinned ABOVE the session list. When the pending file disappears (decision or timeout) → dismiss the card and auto-collapse IF the expansion was programmatic and the pointer is not over the panel.
- **`ApprovalCardView.swift`** (match the reference):
  - Header: `⚠` + tool name amber mono + summary (`Edit src/auth/middleware.ts`) + project name.
  - Body by type: Edit/NotebookEdit → diff block: old lines prefixed `-` on `#3A1D22`-ish red rows (`#FF6B6B` text), new lines prefixed `+` on green rows (`#1E3325` bg, `#7EE787` text), 11pt mono, max ~12 lines with scroll. Write → file path + content preview block. Bash → command in a code block.
  - Buttons row: `Deny` (dark capsule), `Allow Once` (white capsule, dark text — primary), `Bypass` (red capsule, means allow + session scope). 12pt mono bold.
  - Button action → write `~/.vibenotch/decisions/<sessionId>.json` (atomic) with the decision + scope, then optimistically dismiss the card.
- No keyboard shortcuts in this round (panel is non-activating; ⌘Y/⌘N need key-window work — deferred).
- Rest pill: when any pending approval exists, status text says `Approve?` in amber and the pill background pulses subtly (opacity 1.0→0.85, 1s loop, TimelineView).

## 3. Notification hook → needs_me (catches everything the gate doesn't)
`vibenotch-claude-hook` gains `notify` mode: reads Notification payload (`.message`, `.title` or similar), emits status `needs_me` with `--detail "<message first 80 chars>"`. (Manager registers it on the `Notification` event.) A subsequent PreToolUse/UserPromptSubmit/Stop naturally flips the status back.

## 4. Unit tests
- `PendingApproval` decode for all three body types; missing-field tolerance.
- Decision file write shape (encode `ApprovalDecision` and re-decode).

## 5. Polish (small, same round)
- Tighten the dead black band above the panel header (reduce DynamicNotchKit top inset / content top padding to ~6pt).
- Done rows: drop stale toolLine if status != working (already ok — verify).

## Acceptance (manager verifies with a REAL session)
1. `swift build` + `swift test` green.
2. Synthetic: writing a pending file by hand pops the panel with the correct card (Edit diff render, Bash command render); clicking Allow Once writes the decision file and dismisses.
3. Real: a gated `Edit` in a default-mode terminal session pops the card; Allow Once → the edit actually runs in Claude; Deny → Claude reports the tool was denied; no decision → terminal prompt appears after ~20s.
4. Background launchd sessions are never gated (verify email-triage keeps running normally).
5. The approval hook under `set -x` shows instant no-op for: flag off, ttyless, non-write tools, allowlisted Bash prefixes.

Print files created/modified. Do not build. Do not register hooks in settings.json (manager does that).
