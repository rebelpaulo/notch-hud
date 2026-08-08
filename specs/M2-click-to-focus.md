# M2 spec — Click a session to raise its terminal (for GPT-5.6 Sol)

Goal: clicking a session row in the panel raises the Terminal.app window/tab that agent is running in. Primary target is Apple_Terminal (Cooper's terminal); other terminals are pluggable stubs.

## CONSTRAINTS
- DO NOT run swift build/test (sandbox). Write files only. Manager builds + verifies.
- DO NOT change HoverController, NotchGeometry, SpoolWatcher/SessionStore behavior. Additive + wiring.
- CLT-safe (no @Entry/#Preview). @Observable is fine.

## 1. FIX tty capture in `scripts/vibenotch-emit` (critical — click-to-focus needs it)
The current `ps -o tty= -p "$PPID"` returns null because the hook process is often ttyless. FIX: walk the parent-process chain from the emit process upward and take the FIRST ancestor with a real tty. Add a shell function:

```sh
# Find the controlling tty by walking up the ppid chain.
find_tty() {
  pid=$$
  i=0
  while [ "$pid" -gt 1 ] && [ "$i" -lt 25 ]; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$t" in
      ttys*) printf '/dev/%s\n' "$t"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i+1))
  done
  return 0   # empty tty is acceptable (unknown)
}
```
Use `find_tty` result for the `terminal.tty` field. Keep everything else identical. Re-install note: manager copies scripts to ~/.vibenotch/bin.

## 2. Focus module (Sources/Vibenotch/Focus/)

### `FocusStrategy.swift`
```swift
protocol FocusStrategy {
    func canHandle(_ identity: TerminalIdentity) -> Bool
    func focus(_ identity: TerminalIdentity) throws
}
enum FocusError: Error { case notFound, permissionDenied(String), scriptFailed(String) }
```

### `AppleScriptRunner.swift`
Runs an AppleScript via `NSAppleScript`. Returns output or throws `FocusError.permissionDenied` on errAEEventNotPermitted (-1743) / errAEnotHandled, `.scriptFailed` otherwise. (NSAppleScript executes on the main thread — dispatch appropriately; the caller may be off-main.)

### `TerminalAppStrategy.swift` (PRIMARY)
- `canHandle`: identity.termProgram == "Apple_Terminal" AND identity.tty != nil.
- `focus`: run AppleScript that finds the tab whose `tty` matches and raises it:
```applescript
tell application "Terminal"
  activate
  set target to "/dev/ttysXXX"
  repeat with w in windows
    repeat with t in tabs of w
      if (tty of t) is target then
        set selected of t to true
        set index of w to 1
        return "ok"
      end if
    end repeat
  end repeat
end tell
return "notfound"
```
Substitute the real tty. If result is "notfound" throw `.notFound`.

### Stubs (compile-only, return canHandle=false or throw .notFound for now)
`ITerm2Strategy.swift` (weztermPane/itermSessionId based), `WezTermStrategy.swift`, `KittyStrategy.swift`. Keep minimal; they're M-later.

### `FocusDispatcher.swift`
```swift
@MainActor final class FocusDispatcher {
    private let strategies: [FocusStrategy]  // [TerminalAppStrategy(), ITerm2Strategy(), ...]
    func focus(_ session: Session) async -> Result<Void, FocusError>
}
```
Pick first strategy whose canHandle matches session.terminal; run its focus off the main actor (AppleScript can block); return the result. If none match or tty missing, return .failure(.notFound).

## 3. Make rows clickable
- `SessionRowView`: wrap in a Button (or `.onTapGesture`) that calls a closure `onSelect: (Session) -> Void`. Add hover highlight. Keep it accessible (help text "Raise this session's terminal").
- `NotchPanelView`: pass an `onSelect` down that calls `FocusDispatcher.focus(session)`. On `.permissionDenied`, set a transient state on the row showing a small "grant access" affordance (a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`). On `.notFound`, briefly show a subtle "window not found" state.
- Wire a shared `FocusDispatcher` from the app into the views (same pattern as SessionStore).

## 4. Info.plist
Add `NSAppleEventsUsageDescription` = "Vibenotch raises the terminal window of the agent session you click." (Sources/Vibenotch/Info.plist already exists; add the key.)

## Acceptance (manager verifies with a REAL Claude session in Terminal)
1. swift build exits 0; swift test still green.
2. A real Claude session's status file has a non-null `terminal.tty` (the tty walk works).
3. Clicking that session's row raises the correct Terminal window/tab (after granting the one-time Automation prompt).
4. Denying Automation shows the grant affordance rather than silently failing.

When done: print files created/modified. Do not build.
