<div align="center">

<img src="app/AppIcon.iconset/icon_128x128.png" width="96" height="96" alt="Session Pet icon">

# Session Pet

**Know instantly which of your Claude Code sessions needs you** — then approve,
deny, or answer it without leaving what you're doing.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square)
![Swift](https://img.shields.io/badge/swift-6.2-orange?style=flat-square)
![Status](https://img.shields.io/badge/status-personal%20project-lightgrey?style=flat-square)

<br>

<img src="docs/demo.gif" width="480" alt="Session Pet: opening the menu bar dropdown, answering a real AskUserQuestion prompt, then approving a pending Bash command">

▶️ [Watch the full demo video](docs/demo.mp4)

</div>

Running a handful of Claude Code sessions across terminal tabs and tmux panes
makes it easy to lose track of which one is actually waiting on you — a
permission prompt, a plan question, a failed command sitting there quietly.
Session Pet is a small robot that lives in your menu bar and answers that one
question at a glance, then lets you act on it right there: clicking a session
expands it in place, with a real `AskUserQuestion` prompt (its actual options —
answering one sends the real keystroke to that session's pane) or a permission
request with one-click Approve/Deny.

## See what needs you

- **A menu-bar icon that reflects your busiest session** — it's not decoration,
  it's the state of whichever session needs you most:
  - 🟢 **Working** — Claude is actively running a tool
  - 🟠 **Waiting** — a permission request or question needs your input
  - 🔴 **Error** — a tool call just failed
  - ⚪ **Idle** — nothing going on (it dozes off after 20s, Zzz's and all)
- **Every session in one dropdown** — name, working directory, live state, and
  an elapsed-time Pac-Man loader while it's running.

## Act without switching windows

- Approve or deny a permission request, answer an `AskUserQuestion` prompt, or
  read a diff — all inline in the dropdown, no alt-tab to a terminal.
- **System notifications** when a session needs you, even with the dropdown
  closed — click one and it jumps straight to that session.

## Make it yours

- **Rename sessions** so the list reads by name, not raw `cwd` path.
- **Launch at Login** and notification/sound toggles in a native Settings window.
- Full light/dark mode, tuned against Apple's actual system colors in both.

## How it works

Session Pet has two halves:

1. **Claude Code hooks** (`~/.claude/hooks/session-pet/status-hook.sh`) —
   a single shell script wired to `SessionStart`, `UserPromptSubmit`,
   `PreToolUse`, `PermissionRequest`, `Stop`, and `PostToolUseFailure`.
   Each event writes a small JSON status file to
   `~/.claude/session-pet/status/<session_id>.json` describing the
   session's current state, tool, cwd, and tmux pane (for focusing).
2. **The menu-bar app** (this Swift package) — polls that status directory,
   aggregates all live sessions into one dropdown, and renders the
   animated pet icon. It's a plain `NSStatusItem` + `NSPopover`
   (not SwiftUI's `MenuBarExtra`) so a notification click can
   programmatically reopen the dropdown on the right session — something
   `MenuBarExtra` can't do pre-macOS 14.

Subagents (Task-tool spawns) share their parent's `session_id`, so the hook
also keys status files by `agent_id` to avoid a subagent's activity
clobbering its parent's file.

## Installation

### Download (no Xcode required)

Grab `SessionPet-<version>.zip` from the [latest release](../../releases),
unzip it, and drag `SessionPet.app` to `/Applications`.

This build is ad-hoc signed, not notarized (that needs a paid Apple
Developer account) — so on first launch Gatekeeper will refuse to open it
with an "unidentified developer" warning. Two ways past it, either works:

```bash
# one-time terminal command, then launch normally
xattr -cr /Applications/SessionPet.app
```

or **right-click SessionPet.app → Open → Open** (instead of double-clicking)
— macOS remembers your choice after that.

### Build from source

Requires macOS 13+ and Swift 6.2 (Xcode 16+).

```bash
cd app/
./package.sh                 # builds + installs to /Applications/SessionPet.app
open /Applications/SessionPet.app
```

`package.sh` does an ad-hoc code-sign so Gatekeeper doesn't block a locally
built launch (no quarantine flag on files you built yourself). Want a zip to
hand to someone else instead? Run `./dist.sh` — it builds, then packages
`SessionPet.app` into `SessionPet-<version>.zip` via `ditto` (preserves the
code signature; plain zip/Finder-compress doesn't).

### Wire up the Claude Code hook

Copy the hook script into place and make it executable:

```bash
mkdir -p ~/.claude/hooks/session-pet
cp hooks/status-hook.sh ~/.claude/hooks/session-pet/status-hook.sh
chmod +x ~/.claude/hooks/session-pet/status-hook.sh
```

Requires [`jq`](https://jqlang.org/) (`brew install jq`). Then add this to
your `~/.claude/settings.json` (merge into an existing `hooks` key if you
have one):

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-pet/status-hook.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-pet/status-hook.sh" }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-pet/status-hook.sh" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-pet/status-hook.sh" }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-pet/status-hook.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-pet/status-hook.sh" }] }]
  }
}
```

Restart Claude Code sessions (or start a new one) for the hooks to take effect.

## Architecture

```
Sources/SessionPet/
  SessionPetApp.swift    — AppDelegate, NSStatusItem/NSPopover wiring, Settings window
  SessionStore.swift     — polls status dir, aggregates state, posts notifications
  SettingsStore.swift    — UserDefaults-backed preferences
  MenuContentView.swift  — dropdown root view (list + footer)
  RowView.swift          — per-session card (name, state, cwd, actions)
  PetIcon.swift          — the robot's SwiftUI geometry + idle "personality" animations
  IconAnimator.swift     — renders PetIcon to a live-updating NSImage for the menu bar
  PacmanLoader.swift     — elapsed-time loading indicator
  DiffView.swift         — inline diff rendering for tool-call previews
  LoginItem.swift        — Launch-at-Login registration (SMAppService)
  Theme.swift            — spacing/radius/color tokens shared across views
```

## Known limitations

- **Notification icon** shows blank — Notification Center can't resolve a
  bundle icon for an unsigned/unnotarized `LSUIElement` (accessory, no Dock
  icon) app. Fixable with a paid Apple Developer notarization; not worth it
  for a personal tool.
- **Notification-click popover position** can land in the wrong spot if the
  frontmost app is a true fullscreen app (its own macOS Space) — the system
  menu bar has no stable position there. Not fixable in-app.

## Privacy

Everything is local. The hook writes status JSON to
`~/.claude/session-pet/status/` on your own machine; the app only reads that
directory and talks to `tmux`/`osascript`/`ps` to focus panes and post
notifications. Nothing is sent over the network.

## License

MIT — see [LICENSE](LICENSE).
