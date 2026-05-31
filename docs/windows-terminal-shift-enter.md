---
tracks:
  - powershell/install.ps1
  - powershell/windows-terminal-newline.json
  - tmux.conf
---

# Shift+Enter → newline in Windows Terminal

## The problem

Windows Terminal sends a bare carriage return (`0x0d`) for **Shift+Enter** —
byte-identical to plain Enter. Any REPL that wants "Enter submits, Shift+Enter
inserts a newline" (Claude Code, the Cursor CLI, PSReadLine multi-line, …) can't
distinguish them, so Shift+Enter just submits. This is a long-standing Windows
Terminal limitation tracked in [microsoft/terminal#530][530]; other terminals
(Ghostty, iTerm2, WezTerm, kitty) send a distinct sequence natively.

Verify on a given machine — in a **plain WSL shell, outside tmux** (so tmux's
own key handling doesn't rewrite the bytes), run `xxd`, press Shift+Enter, then
Ctrl+C:

- a line containing only `0d` → bare CR → the binding below is needed.
- `1b 5b 31 33 3b 32 75` (`^[[13;2u`) → already distinguished → nothing to do
  (you're on Windows Terminal Preview 1.25+, which added the kitty keyboard
  protocol, or another terminal entirely).

## The fix

Bind Shift+Enter to a `sendInput` action that emits the CSI-u encoding of
Shift+Enter (`\u001b[13;2u`, i.e. ESC followed by `[13;2u`):

```json
{ "command": { "action": "sendInput", "input": "\u001b[13;2u" }, "keys": "shift+enter" }
```

This sequence is what the rest of the stack already expects:

- **Bare Claude Code (no tmux):** Claude Code's extended-keyboard support reads
  it as Shift+Enter and inserts a newline.
- **Inside tmux** (the usual case here — `claude` is wrapped in tmux): `tmux.conf`
  sets `extended-keys csi-u`, decodes `\u001b[13;2u` as the `S-Enter` key, and its
  root binding forwards `C-j` (Claude's alternate newline binding) while
  `@claude-running` is set. See the Shift+Enter block in `tmux.conf`.

## Why this lives in the user's settings.json (and not a fragment)

The cleaner option would be a **Windows Terminal fragment extension** — a
standalone JSON file dropped into `…\Windows Terminal\Fragments\` that WT merges,
never touching the user's own `settings.json`. Fragments can carry `actions`
since WT 1.21, **but they cannot bind keys**: a `keys` field on a fragment action
is silently ignored, closed as *Resolution-By-Design* in
[microsoft/terminal#17240][17240]. So a fragment can define the action but never
attach Shift+Enter to it — useless here.

That leaves editing `settings.json` directly, which is what every documented fix
does.

## What `install.ps1` does

`powershell/install.ps1` (`Add-WTNewlineBinding`) applies this automatically and
idempotently on install / re-run:

1. The binding is defined once, canonically, in
   `powershell/windows-terminal-newline.json` (single source of truth; also the
   thing to paste manually).
2. It looks for `settings.json` in the three standard locations — Store
   (`%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\`),
   Preview (`…WindowsTerminalPreview…`), and unpackaged
   (`%LOCALAPPDATA%\Microsoft\Windows Terminal\`).
3. For each that exists, it **surgically inserts** the binding into the existing
   `actions` (or legacy `keybindings`) array via a single regex replacement,
   leaving the rest of the file — comments, formatting, key order — byte-for-byte
   intact. If no such array exists, it adds one after the root brace.
4. It is **idempotent**: if the binding (`13;2u`) is already present it no-ops,
   and if Shift+Enter is already bound to something else it leaves the file
   alone and warns. A timestamped `*.dotfiles-<ts>.bak` is written before any
   change.

There is no migration for this (the Windows side has no migration runner — see
CLAUDE.md); re-running `install.ps1` covers existing machines.

## Manual fallback

If you don't run `install.ps1`, open Settings → "Open JSON file" in Windows
Terminal and add the object above to the `actions` array. WT picks up the change
immediately — no restart needed.

## When this becomes unnecessary

Windows Terminal **Preview 1.25** added support for the kitty keyboard protocol,
which lets apps negotiate unambiguous key reporting at runtime — once that
reaches stable and an app opts in, Shift+Enter is distinguishable with no
keybinding at all. Until then, the binding is required on stable WT.

[530]: https://github.com/microsoft/terminal/issues/530
[17240]: https://github.com/microsoft/terminal/issues/17240
