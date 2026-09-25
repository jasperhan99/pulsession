# Session monitor (Pulsession)

Pulsession is a fork of Pulse that adds a **session monitor**: one more ring on the rail, after the accounts, whose card lists every recent agent session and what it is doing. It grew out of the *Session Monitor* widget for PI-Desktop, which ran as a PI-Desktop plugin. This fork runs on its own, without PI-Desktop's plugin host.

Everything else — usage rings, cards, the animated mark, glass, placement, Settings — is upstream Pulse, unchanged in behaviour. Code for this feature lives in `Sources/Pulse/Sessions/` and `Settings/SessionsSettingsView.swift`. Upstream files are touched only at small, commented seams, so merges from `upstream/main` stay tractable.

## Sources

| Source | Read from | States it can report |
|---|---|---|
| PI-Desktop | `~/.pi-desktop/pi.sqlite` (read-only), `~/.pi-desktop/logs/app/permission.log`, optionally its control port | running, waiting for approval, finished, failed, interrupted, idle |
| Claude Code | `~/.claude/projects/**/*.jsonl` modified in the last day, plus the Claude app's session index for links and titles | running, finished, interrupted, idle |
| Codex | `~/.codex/sessions/**/*.jsonl` modified in the last day | running, finished, interrupted, idle |

- **PI-Desktop** (`PiDesktopSessionReader`):
  - Sessions and projects come from `sessions` ⋈ `projects`. Each session's newest `turns` row gives its state: `running`, `completed`, `failed` or `aborted`.
  - A unique index allows only one running turn per session. PI-Desktop rewrites leftover running rows to `aborted` when it next starts, so a running row while PI-Desktop is **not** running is shown as interrupted.
  - A `permission.requested` line with no `permission.resolved` line, for the running turn and less than 15 minutes old, means waiting for approval.
  - Schema evidence: PI-Desktop 0.15.7, `PRAGMA user_version` 19. Another version is flagged in Settings and still read. A query that no longer prepares yields no rows, never an error.
- **Claude Code / Codex** (`CLISessionReader`):
  - Per-file `AgentActivity.verdict`: the same exact lifecycle reading that turns the usage ring, applied to each transcript instead of each provider.
  - The title is the CLI's own name (`customTitle`, `summary`) if there is one, otherwise the opening prompt. The project is the stated `cwd`.
  - **Never "waiting":** neither CLI records a pending approval in a form that can be told apart from a slow tool.

A finished, failed or interrupted outcome is shown for 30 minutes (`SessionState.outcomeWindow`). After that the session is idle.

## Opening Claude Code and Codex sessions

Most of these are desktop-app sessions, not terminal ones. Claude Code transcripts from the Claude app carry `"entrypoint":"claude-desktop"`, and Codex rollouts from the Codex app carry `originator` `codex_work_desktop`. So a click opens the session in its app (`DesktopAppLinks`):

- **Claude:** `claude://code/continue?session=local_…`.
  - The id is the app's own. It is found in `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`, whose `cliSessionId` is the transcript's id.
  - Only `sessionId`, `cliSessionId`, `title` and `isArchived` are read.
  - The app's title replaces the opening prompt.
  - A session archived in the Claude app is left out.
  - Evidence: Claude's `claudeURLHandler` accepts `last` or `^local_[A-Za-z0-9-]{1,64}$` on `/continue`.
- **Codex:** `codex://threads/<session_meta id>`, whenever the Codex app (`com.openai.codex`) is installed. It lists every rollout under `~/.codex`.

A session no app holds — Claude Code started in a terminal — keeps the old behaviour and copies `cd … && claude --resume <id>`. The row menu offers **Open in Claude / Codex** and **Copy resume command** side by side.

## PI-Desktop control port

PI-Desktop has no URL scheme and ignores what a second launch passes it. When it is started with `PI_DESKTOP_MCP_CONTROL=1` in its environment, it serves MCP over HTTP on `127.0.0.1` (default port 37123) behind a bearer token. It writes the URL and token to `~/.pi-desktop/mcp-control.json` (mode 0600).

`PiDesktopControl` uses it when **Use PI-Desktop control** is on and the file says it is active. It calls:

- `pi_desktop_invoke` `session/open`, so clicking a row opens that conversation.
- `agent/getStatus`, whose `pendingToolConfirmations` replaces the permission-log guess.

The client refuses any non-loopback URL and bypasses Pulse's proxy settings.

Pulsession never starts the port on its own. **Settings › Sessions › Restart with control on** asks first, then quits PI-Desktop and reopens it with the variable set (`PiDesktopLauncher.relaunchWithControl`). Quitting stops a running turn, which is why it asks. Without the port, clicking a PI-Desktop row brings PI-Desktop forward, and the card says why it did not open the session itself.

## Panel integration

- **Rail.**
  - `AppSettings.extraRailSlots` (not persisted; set by `AppDelegate` from `SessionSettings.isEnabled`) is counted into `railSlotCount` and `FloatingPanelController.shownSlotCount`. The window and the view agree on the rail's length through this one number.
  - `SessionsDockItem` takes exactly one item's budget, like every ring.
- **Ring** (`SessionsRingView`).
  - One arc per visible session (up to 12), coloured with Pulse's own vocabulary:
    - white: running
    - amber: waiting on a person
    - red: failed
    - green: finished
  - Pulse's white travelling mark shows while any session runs. A slow amber breath shows while one waits for approval.
  - The optional animated mark (`SessionSettings.showsBotMark`, off by default like the per-account marks) plays `workFinished` when the monitor witnesses a turn end.
  - The label under the ring is a count of active sessions, never a percentage.
- **Card** (`SessionsCard`).
  - Occupies the same overlay slot as `UsageDetailCard`, drawn in the same `UsageBubbleShape` on the same `PanelSurface`.
  - Rows are budgeted from `DetailCardLayout` (`SessionCardLayout.maximumRows`), so the card never needs a taller window.
  - Rows publish their frames in `BotMarkView.panelSpace` to `SessionCardHitMap`.
- **Input.**
  - Per Docs/ui/input.md, the rows have no SwiftUI controls. `FloatingPanel.sendEvent` turns a press and release on the same row into `SessionMonitor.open`, and a secondary click into `SessionRowMenu`.
  - The row menu offers open / copy resume command, hide until the next turn ends, archive, and a link to the Settings pane.
  - While that menu is up, `pointerMoved` leaves the card open.
  - A click on the ring itself re-reads, as a click on a usage ring refreshes it.
- **Expansion.** `FloatingUsagePanelView.isExpanded` also holds the rail out while `SessionMonitor.holdsRailOpen`: a visible session is running or waiting, and **Keep the rail out while a session is active** is on.

## Hide and archive

These change only what Pulsession shows; no conversation is modified. Entries live in `SessionSettings` (`sessions.hidden` and `sessions.archived` in UserDefaults, 200 each at most). An entry keeps the title and project, so Settings can name a session that has since dropped out of the readers' lists.

A **hidden** session comes back when a turn ends after it was hidden:

- For PI-Desktop, the database dates every turn, so this is exact.
- For the CLIs, it is an active→ended transition the monitor saw.

An **archived** session stays out until it is restored in **Settings › Sessions**.

## Clock

`SessionMonitor` runs its own 2-second timer, like `AgentActivityMonitor`. It is paused while the panel is hidden or the display is asleep (`UsageStore.updateSessionMonitor`). Scans run detached; a scan that outlives `stop()` is discarded by generation.

## Tests

`Tests/PulseTests/SessionMonitorTests.swift` covers:

- the database reader against a schema-19 database built in a temporary home
- permission-log rules
- status mapping
- CLI metadata parsing and verdict mapping
- resume-command quoting
- visibility persistence
- the control port's result shapes and connection-file trust

No test reads the user's own files.
