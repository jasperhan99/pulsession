<p align="center">
  <img src="AppIcon/pulse-icon-1024.png" width="112" alt="Pulsession">
</p>

<h1 align="center">Pulsession</h1>

<p align="center">
  <b>Your AI coding allowances and your agent sessions, on one ring at the edge of the screen.</b><br>
  A fork of <a href="https://github.com/qunqin24/Pulse">Pulse</a> that adds a live session monitor for PI-Desktop, Claude Code and Codex.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-333333?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue" alt="Apache 2.0"></a>
  <a href="https://github.com/qunqin24/Pulse"><img src="https://img.shields.io/badge/based%20on-Pulse-black" alt="Based on Pulse"></a>
</p>

<p align="center">
  <sub><b>English</b> · <a href="README.zh-CN.md"><b>简体中文</b></a></sub>
</p>

---

## What Pulsession is

**[Pulse](https://github.com/qunqin24/Pulse)**, by qunqin24, is a small floating monitor that docks to the edge of your screen. It shows how much of each AI coding plan you have left: Claude Code, Codex, Cursor, Copilot and seventy-odd more. Pulsession keeps all of it — the rings, the detail cards, the animated bot mark, Liquid Glass, placement, notifications, token spend — exactly as Pulse designed it.

What Pulsession adds is **one more ring**: the **session monitor**. Point at it and a card lists every recent agent session, what each one is doing, and for how long. Click a row and the conversation opens in the app that holds it.

Pulsession began as a *Session Monitor* widget running inside PI-Desktop as a plugin. It is now a standalone macOS app built on Pulse, so it needs no plugin host.

## The session monitor

### The ring

The ring sits on the rail after your accounts and has one arc per session. Colours follow Pulse's own language:

| Colour | Meaning |
|---|---|
| White | Running — a turn is in flight |
| Amber | Waiting for you — a tool call needs approval |
| Red | The last turn failed |
| Green | Finished (for 30 minutes, then idle) |
| Grey | Interrupted, or idle |

- **Motion.** While any session runs, Pulse's white travelling mark circles inside the ring. While one waits for approval, a slow amber breath pulses outside it.
- **Animated mark.** You can turn on Pulse's bot mark for the ring; it celebrates when a turn finishes.
- **Label.** The number under the ring counts active sessions. It is never a percentage.
- **Keeps the rail out.** While a session is running or waiting, the rail stays drawn out instead of hiding to its sliver. You can switch this off.

### The card

Each row shows:

- a state mark
- the project name
- the session title
- the state and source
- the elapsed time (for a running turn) or how long ago it last changed

| Action | Result |
|---|---|
| **Click** a Claude Code session | Opens it in the **Claude app's** Code tab (`claude://code/continue?session=…`) |
| **Click** a Codex session | Opens it in the **Codex app** (`codex://threads/<id>`) |
| **Click** a PI-Desktop session | Opens it in **PI-Desktop** through its local control port (see below); otherwise brings PI-Desktop forward |
| **Click** a terminal-only session | Copies `cd <project> && claude --resume <id>` (or `codex resume <id>`) to the clipboard |
| **Right-click** a row | Open · Copy resume command · Show project in Finder · **Hide until its next turn ends** · **Archive** |
| **Click** the ring | Re-reads every session now |

Hiding and archiving only change what Pulsession shows; no conversation is touched. Hidden sessions come back on their own when their next turn ends. Archived ones stay out until you restore them in **Settings › Sessions**.

### Where sessions come from

Everything is read locally and read-only. Nothing is uploaded.

| Source | Read from | States |
|---|---|---|
| **PI-Desktop** | `~/.pi-desktop/pi.sqlite` (sessions, projects, turns) and `logs/app/permission.log` | running, waiting for approval, finished, failed, interrupted |
| **Claude Code** | `~/.claude/projects/**/*.jsonl` from the last day, plus the Claude app's own session index for titles and links | running, finished, interrupted |
| **Codex** | `~/.codex/sessions/**/*.jsonl` from the last day | running, finished, interrupted |

- Running and finished states for Claude Code and Codex use the same exact lifecycle reading that drives Pulse's activity mark: `stop_reason`, and `task_started` / `task_complete`.
- Neither CLI records a pending approval in a form that can be told apart from a slow tool, so Pulsession does not guess at one.
- Each source can be switched off in **Settings › Sessions**.

### PI-Desktop's control port

PI-Desktop has no URL scheme. To open a *specific* PI-Desktop session, and to read pending approvals exactly, Pulsession uses PI-Desktop's own local MCP control server.

- **When it runs.** PI-Desktop starts the server only when launched with `PI_DESKTOP_MCP_CONTROL=1`.
- **Turning it on.** **Settings › Sessions › Restart with control on** asks first, then quits PI-Desktop and reopens it with the port on. Quitting stops a running turn.
- **Scope.** The port listens on `127.0.0.1` only. Its token is read from PI-Desktop's own file, never leaves your Mac, and bypasses any proxy.
- **Without it.** Everything else still works: the permission log stands in for approvals, and a click brings PI-Desktop forward.

## Everything else is Pulse

All of Pulse's features are here unchanged:

- usage rings with smart colouring
- detail cards with every limit and its reset time
- optional burn-rate forecast, window clock and second ring
- the animated bot mark
- docking to the left, right or top edge
- Liquid Glass
- multi-display support
- opt-in notifications
- token spend across 50+ local clients
- `--json` output, extensions and developer integrations

See the [Pulse README](https://github.com/qunqin24/Pulse#readme) for the full tour and the provider table. The design notes in [Docs/](Docs/README.md) describe this codebase.

## Install

There are no prebuilt releases yet. Build from source.

**Requirements:** macOS 14 or later to run. Building needs **Xcode 26 or later** (the macOS 26 SDK), selected with `xcode-select`.

```bash
git clone https://github.com/jasperhan99/pulsession.git
cd pulsession
./Scripts/bundle.sh
open build.noindex/Pulsession.app
```

Move `Pulsession.app` to `/Applications` if you want to keep it. The build is ad-hoc signed, so the first launch of a downloaded copy may need **right-click › Open**.

On first launch, choose at least one service to monitor. The rail, and the sessions ring on it, appear once a service is chosen. Like Pulse, Pulsession turns on **Open at login** the first time it runs; switch it off in **Settings › General**.

## How Pulsession differs from Pulse

Pulsession can run beside an installed Pulse without sharing anything:

| | Pulse | Pulsession |
|---|---|---|
| Bundle identifier | `io.github.qunqin24.Pulse` | `io.github.jasperhan.pulsession` |
| Data folder | `~/Library/Application Support/Pulse` | `~/Library/Application Support/Pulsession` |
| URL scheme | `pulse://` | `pulsession://` |
| Updates | Sparkle feed | None yet — rebuild to update |
| Session monitor | — | ✓ |

The Swift module and executable target are still named `Pulse` inside the package; only the app bundle carries Pulsession's name.

## Development

```bash
swift build
swift test
./Scripts/check-localization.sh
```

- **Architecture.** The session monitor lives in `Sources/Pulse/Sessions/`. Upstream files are touched only at small, commented seams. The design, evidence and rules are in [Docs/sessions.md](Docs/sessions.md).
- **Upstream rules.** Pulse's rules for panel geometry, input, localization and evidence still apply; see [CLAUDE.md](CLAUDE.md), [CONTRIBUTING.md](CONTRIBUTING.md) and [Docs/](Docs/README.md).
- **Languages.** The interface is in English, Simplified Chinese, Traditional Chinese, Japanese and Korean.

## Credits

- **[Pulse](https://github.com/qunqin24/Pulse)** by qunqin24 and contributors is the app Pulsession is built on. Everything outside the session monitor is their work. If you only want the usage monitor, use Pulse.
- Pulse's design was inspired by a UI concept shared by [**Vinz** (@hivinz_)](https://x.com/hivinz_/status/2092996055248126353) on X.
- Provider marks come from [Lobe Icons](https://github.com/lobehub/lobe-icons). The animated mark and other bundled assets keep their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[Apache 2.0](LICENSE), as Pulse. [NOTICE](NOTICE) lists what Pulsession changed.
