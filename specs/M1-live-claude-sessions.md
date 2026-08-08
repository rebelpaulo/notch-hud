# M1 spec — Real Claude session status end-to-end (for GPT-5.6 Sol)

Goal: replace the hardcoded 3 sessions with LIVE data read from a spool folder that agent hooks write to. After this milestone, opening a real Claude Code session in Terminal makes a row appear (Working), and when the turn ends it flips to Done.

Scope for M1: Claude Code only, two events (working on prompt submit, done on stop). Full state machine (needs_me, staleness) is M3. The manager installs the Claude settings.json hooks separately, you only write the emitter scripts + the Swift that reads the spool.

## CONSTRAINTS
- DO NOT run `swift build`/`swift test` (sandbox). Only write files. Manager builds + verifies.
- DO NOT change HoverController / NotchGeometry / hover behavior. Additive work + wiring only.
- Keep everything compiling under Command Line Tools (no `@Entry`/`#Preview` macros; `@Observable` is fine).

## 1. Model files (Sources/Vibenotch/Model/)

### `SessionStatus.swift`
```swift
enum SessionStatus: String, Codable, Sendable {
    case starting, working, needs_me, done, unknown
}
```
Plus a `DisplayStatus` (working / needsMe / done / idle) computed from it, with an associated SwiftUI `Color` and a short label. Colors: working `#0A84FF`, needsMe `#FFD60A`, done `#30D158`, idle `#48484A`.

### `TerminalIdentity.swift`
`Codable, Sendable` struct: `termProgram: String?`, `tty: String?`, `itermSessionId: String?`, `weztermPane: String?`, `kittyWindowId: String?`, `windowId: String?`. All optional.

### `SessionEnvelope.swift` (the on-disk wire type — matches the JSON the scripts write)
`Codable, Sendable` struct with exactly:
`schema: Int`, `id: String`, `agent: String`, `pid: Int?`, `project: String?`, `cwd: String?`, `status: SessionStatus`, `detail: String?`, `updated: String` (ISO8601), `started: String?`, `seq: Int`, `terminal: TerminalIdentity?`, `source: String?`.
Use a decoder that tolerates missing optional keys.

### `Session.swift`
The in-memory model the UI uses: `id`, `agent`, `project` (fallback to basename of cwd, else id), `status`, `detail`, `updatedAt: Date`, `seq`, `terminal`. Init from a `SessionEnvelope`. Provide `displayStatus`.

## 2. Store + watcher (Sources/Vibenotch/Store/)

### `SpoolReader.swift`
Reads one `<id>.json` file: `Data(contentsOf:)`, JSON-decode to `SessionEnvelope`, return `Session?` (nil on decode failure — caller retries next tick). ISO8601 parsing via `ISO8601DateFormatter` (with fractional seconds).

### `SpoolWatcher.swift`
- `DispatchSource.makeFileSystemObjectSource(fileDescriptor: open(spoolDir, O_EVTONLY), eventMask: [.write,.delete,.rename,.extend], queue: <serial ioQueue>)`.
- On event: debounce ~150ms, then RESCAN the directory (`contentsOfDirectory`), decode every `*.json`, and hand the resulting `[Session]` to the store on the main actor. (Rescan-on-signal, not delta interpretation.)
- Enforce `seq` monotonicity per id (ignore a decoded session whose seq < the one already held, unless the file's `updated` is strictly newer — keep it simple: prefer higher seq).
- Handle the spool dir not existing yet (create it) and being deleted/recreated (reopen with backoff).
- Provide `start()` / `stop()`.

### `SessionStore.swift`
- `@Observable @MainActor final class SessionStore`.
- Holds `private(set) var sessions: [Session]` sorted (needs_me first, then working, then done; then by updatedAt desc).
- `func apply(_ sessions: [Session])` replaces state from a rescan.
- Computed summary for the peek: `counts: (working: Int, needsMe: Int, done: Int)` and `total`.

## 3. Wire the UI to live data
- `AppEnvironment` already owns `spoolURL`. Create a single `SessionStore` and `SpoolWatcher` in `VibenotchApp`/`AppDelegate`, start the watcher, and inject the store into the SwiftUI views (as `@Environment` or passed in).
- `NotchPeekView`: show `store.total` and up to 3 colored dots reflecting the real status mix (or a compact "n" + dots). Use `.monospacedDigit()`.
- `NotchPanelView`: list the real `store.sessions` via `SessionRowView` (project name + status dot + optional detail). Empty state: "No active sessions".
- `SessionRowView`: dot color from `displayStatus`, project name, subtle secondary detail.
- IMPORTANT: `NotchWindowManager` builds the DynamicNotch with `NotchPeekView()`/`NotchPanelView()` closures — make those views observe the shared store so they update live. Pass the store into the views.

## 4. Emitter scripts (write to repo `scripts/`, they get installed to ~/.vibenotch/bin/ by the manager)

### `scripts/vibenotch-emit`  (POSIX sh, `chmod +x`)
Usage: `vibenotch-emit <id> <agent> <status> [--detail TEXT] [--project DIR] [--cwd DIR] [--pid N] [--remove]`
- Spool dir: `${VIBENOTCH_HOME:-$HOME/.vibenotch}/sessions` (mkdir -p).
- Capture terminal identity from inherited env: `TERM_PROGRAM`, `ITERM_SESSION_ID`, `WEZTERM_PANE`, `KITTY_WINDOW_ID`, and tty via `ps -o tty= -p "$PPID" 2>/dev/null` (prefix `/dev/`), fallback `tty`.
- Maintain a per-id seq counter file at `<spool>/../seq/<id>` (mkdir -p), increment each write.
- Build JSON with `jq -n` (jq is available). Fields per the SessionEnvelope schema (schema=1, updated = ISO8601 UTC `date -u +%Y-%m-%dT%H:%M:%SZ`).
- Atomic write: write to `<id>.json.tmp.$$` then `mv -f` to `<id>.json`.
- `--remove` deletes `<id>.json` (and seq file).
- Always `exit 0` fast.

### `scripts/vibenotch-claude-hook`  (POSIX sh, `chmod +x`)
Usage: `vibenotch-claude-hook <status>` where status ∈ starting|working|needs_me|done|remove.
- Read hook JSON from stdin, extract with jq: `.session_id`, `.cwd`.
- Compute id = `claude-<session_id>`, project = basename of cwd.
- If status == remove → call `vibenotch-emit "$id" claude-code remove --remove`.
- Else → call `vibenotch-emit "$id" claude-code "$status" --cwd "$cwd" --project "$project"`.
- Must `exit 0` always (never block Claude). Tolerate missing jq/fields gracefully.

## 5. Provide a manual test fixture
`scripts/vibenotch-fixture.sh` — writes 2 fake session files directly (one working, one done) so the manager can verify the watcher/UI without a real Claude session. Just calls vibenotch-emit twice with fake ids.

## Acceptance (manager verifies — do not self-certify)
1. `swift build` exits 0; `swift test` still green.
2. Running `scripts/vibenotch-fixture.sh` creates files under `~/.vibenotch/sessions/`, and the running app's peek count + panel reflect them within ~1s (watcher works).
3. With the manager-installed Claude hooks, a real Claude session shows Working on prompt submit and Done on stop.

When done: print files created/modified. Do not build.
