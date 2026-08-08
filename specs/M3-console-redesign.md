# M3 spec — Console redesign + rich live status (for GPT-5.6 Sol)

The current UI (count + dots peek, plain "Active sessions" list) is wrong. Rebuild it to match the interaction/information design in `assets/reference/*.jpg` (Vibe Island frames — study all 5 before writing code). This milestone is the READ-ONLY console: rich rows + live tool activity + terminal aesthetic. Inline approvals are M4, do not build them yet.

## CONSTRAINTS
- DO NOT run swift build/test (sandbox). Write files only; manager builds.
- CLT-safe: no `@Entry` / `#Preview` macros. `@Observable` + `Canvas` + `TimelineView` are fine.
- Do not touch HoverController hit-zone logic or NotchGeometry tests except where this spec says (expanded rect, see §6).
- Our own sprite art (see §4) — do NOT copy Vibe Island's sprites pixel-for-pixel.

## 1. Extend the wire schema (additive, schema stays 1)
`SessionEnvelope` gains optional fields (tolerant decode):
- `task: String?` — short task title (first prompt, truncated ~60 chars)
- `prompt: String?` — latest user prompt (full, UI truncates)
- `toolLine: String?` — current activity, e.g. `Bash npm test -- agent-events`, `Edit App.tsx`
- `model: String?` — e.g. `fable-5`, `opus-4.8`
`Session` mirrors these; also add `startedAt: Date?` and computed `elapsed: String` ("<1m", "7m", "1h", "5h", "2d").

## 2. Emitter upgrades (scripts/)
### vibenotch-emit
New optional flags: `--task TEXT`, `--prompt TEXT`, `--tool-line TEXT`, `--model TEXT`. Include in JSON when present. **Preserve fields across writes:** when updating an existing `<id>.json`, merge — a status-only update must NOT wipe task/prompt/toolLine/model/started (read old file with jq, overlay new values). `started` is set once on first write.
### vibenotch-claude-hook
- `working` mode: also extract `.prompt` from stdin → pass `--prompt` and, if no task recorded yet, `--task` (first 60 chars, single line).
- NEW `tool` mode (`vibenotch-claude-hook tool`): reads PreToolUse payload (`.tool_name`, `.tool_input`). Build a one-line summary:
  - Bash → `Bash <first 48 chars of .tool_input.command>`
  - Edit/Write/Read/NotebookEdit → `<tool> <basename of .tool_input.file_path>`
  - Grep/Glob → `<tool> <.tool_input.pattern, 32 chars>`
  - Task/Agent → `Agent <.tool_input.description // "subtask">`
  - anything else → tool name
  Emit status `working` with `--tool-line`. Also try `.model // empty` from any payload → `--model`.
- `starting` mode: capture `.model` if present.
All modes stay `exit 0`, fast, tolerant of missing fields.

## 3. Compact (resting) notch — an information surface
Use both DynamicNotchKit compact slots:
- **compactLeading:** up to 3 agent sprites (§4, 12×12pt each, state-colored) + mono status text: `Working…` (white) when any session working; `Needs you` (amber #FF9F0A) when any needs_me (priority); `Done` (green #30D158) when all done; nothing when no sessions.
- **compactTrailing:** `N sessions` in secondary mono (only when N > 0).
Font: `.system(size: 11, weight: .medium, design: .monospaced)`.

## 4. Pixel sprite component (our own art)
`Sources/Vibenotch/Notch/AgentSprite.swift` — SwiftUI `Canvas` rendering an 8×8 pixel-grid creature; define 2 frames (idle bob) as `[[UInt8]]` bitmaps. ORIGINAL design: a small round-ish "blob bot" with 2 eyes and little legs (not Space Invaders). Color by DisplayStatus: working `#0A84FF` animated at ~1.2s frame swap via `TimelineView(.periodic)`; needsMe `#FF9F0A` blinking (alternate alpha 1.0/0.55); done `#30D158` static; idle `#48484A` static. Size parameterized (12pt compact, 18pt rows).

## 5. Expanded panel — the console (match `vibeisland-session-list.jpg` info design)
Overall: width ~680pt, charcoal `Color(red:0.078,green:0.078,blue:0.086)` at 97%, corner radius 22 (bottom corners), 0.5pt stroke white 8%, content padding 14.
- **Header row:** left = mono summary `2 working · 1 needs you · 1 done` (colored counts); right = small gear icon (SF Symbol, no action yet) — keep minimal, usage meters come later.
- **Session cards** (rounded 12, white 4% fill, 10pt vertical padding, hover highlight white 8%):
  - Leading: AgentSprite 18pt.
  - Line 1: `project` bold mono 13 + ` · ` + task title (regular, secondary, truncated).
  - Line 2: `You: <prompt>` 11pt mono secondary, truncated 1 line.
  - Line 3 (only when toolLine present and status is working): toolLine 11pt mono in accent — first word (tool name) in `#6EB4FF`, rest secondary. When status done: `Done — click to jump` in green 11pt mono.
  - Trailing chip stack (right-aligned, 9pt mono, capsule fills white 6%): agent chip (`Claude` tinted #D97757, `Codex` tinted white-on-dark, else gray), model chip if present (`Fable 5`, `GPT-5.6`), terminal chip (`Terminal`, `iTerm2` — map Apple_Terminal→Terminal), elapsed (`7m`). Below chips: 6pt status dot.
  - Whole card clickable (existing FocusDispatcher wiring stays).
- Sort: needs_me → working → done (existing store sort). Empty state: sprite + `No active sessions` mono.
- Background sessions (tty == nil): show dimmed (55% opacity) at the bottom of their status group, no focus affordance.
- Elapsed refresh: 30s `TimelineView(.periodic)` around the list (or store timer) so `7m` ticks without spool events.

## 6. Expanded hover rect must track the REAL panel
`NotchWindowManager.containsExpandedContent(at:)` currently uses hardcoded 370×230 via `NotchGeometry.expandedContentRect`. Replace the hardcoded size with the ACTUAL expanded window frame: if `isExpanded`, read `notchedHUD?.windowController?.window?.frame` (fall back to the geometry helper with width 720 height 460 if the window is unavailable). Keep `NotchGeometry.expandedContentRect` and its tests intact (still used as fallback) — update the two fallback constants where called, not the pure function.

## 7. Files
New: `AgentSprite.swift`. Modified: `SessionEnvelope.swift`, `Session.swift`, `SessionStatus.swift` (chip/tint helpers), `NotchPeekView.swift` (compact leading), new `NotchPeekTrailingView.swift`, `NotchPanelView.swift`, `SessionRowView.swift`, `NotchWindowManager.swift` (compact slots + §6), `scripts/vibenotch-emit`, `scripts/vibenotch-claude-hook`.

## 8. Unit tests (extend Tests/VibenotchTests)
- Envelope decode with and without the new optional fields.
- Elapsed formatting: 30s→"<1m", 420s→"7m", 3900s→"1h", 90000s→"1d".
- Tool-line construction is shell-side; instead test `Session.init` maps new fields + merge-preservation expectation documented.

## Acceptance (manager verifies)
1. `swift build` + `swift test` green (new tests included).
2. Fixture sessions with prompt/toolLine/model render the full card layout (screenshot check).
3. Real Claude session: submitting a prompt shows `You: <prompt>`; each tool use updates the live tool line within ~1s; rest state shows sprites + `Working…`; finishing shows `Done — click to jump`.
4. Status-only updates do not wipe task/prompt (merge works — verify by watching a file across Stop).

Print files created/modified when done. Do not build.
