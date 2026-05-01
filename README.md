# Claude Terminal Hook Colors

Visual feedback for Claude Code sessions in Windows Terminal. Each tab independently changes color based on Claude's state, so you can tell at a glance which tabs need your attention.

| State | Meaning |
|-------|---------|
| Processing | Claude is working |
| Stopped | Claude finished, needs your input |
| Permission prompt | Claude is waiting for permission |

Colors reset to your default terminal theme after 15 seconds (configurable).

## Color Profiles

Pick from a curated set during install, or define your own. Each profile uses three colors that map to the states above:

| Profile | Vibe | Processing | Permission | Stopped |
|---------|------|------------|------------|---------|
| **Classic** *(default)* | Bold traffic-light | ![](https://img.shields.io/badge/rgb%3A4d%2F00%2F00-4d0000?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A4a%2F00%2F80-4a0080?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A00%2F4d%2F00-004d00?style=for-the-badge) |
| **Ocean** | Cool blues and greens | ![](https://img.shields.io/badge/rgb%3A00%2F22%2F55-002255?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A2a%2F00%2F6e-2a006e?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A00%2F4d%2F4d-004d4d?style=for-the-badge) |
| **Sunset** | Warm tones | ![](https://img.shields.io/badge/rgb%3A5a%2F15%2F00-5a1500?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A5a%2F00%2F3d-5a003d?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A55%2F4a%2F00-554a00?style=for-the-badge) |
| **Forest** | Earthy / natural | ![](https://img.shields.io/badge/rgb%3A4a%2F2a%2F00-4a2a00?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A3a%2F15%2F3a-3a153a?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A0d%2F3d%2F1a-0d3d1a?style=for-the-badge) |
| **Mono** | Subtle low-contrast | ![](https://img.shields.io/badge/rgb%3A20%2F20%2F20-202020?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A2a%2F2a%2F4a-2a2a4a?style=for-the-badge) | ![](https://img.shields.io/badge/rgb%3A38%2F38%2F38-383838?style=for-the-badge) |
| **Custom** | Your choice | Enter your own `rgb:RR/GG/BB` triples | | |

## Prerequisites

- [Windows Terminal](https://aka.ms/terminal) (v1.22+)
- [PowerShell 7+](https://aka.ms/powershell) (`pwsh`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Install

```powershell
git clone https://github.com/nick-vales-114980/claude-terminal-hook-colors.git
cd claude-terminal-hook-colors
pwsh ./install.ps1
```

The installer asks you to pick a color profile and whether to enable notification sounds, compiles a native DLL for faster startup, and registers the hooks in your Claude Code settings. The hook scripts run directly from the cloned repo — nothing is copied to your user profile.

## Reconfigure

Re-run the installer at any time to change your profile, toggle sounds, or refresh the hook registration:

```powershell
pwsh ./install.ps1
```

When an existing install is detected, you get a menu:

```
1) Change color profile
2) Toggle sounds on/off
3) Reconfigure everything (profile + sounds)
4) Reinstall hooks (refresh settings.json + recompile DLL)
5) Uninstall
6) Cancel
```

Each option only touches what it needs to — your other config (e.g. `stopResetDelaySeconds`, `debug`) and the working hook registration are preserved.

### Non-interactive flags

Useful for scripted setup or CI:

```powershell
pwsh ./install.ps1 -Palette ocean -Sounds off
pwsh ./install.ps1 -Palette sunset
pwsh ./install.ps1 -Sounds on
```

`-Palette` accepts `classic`, `ocean`, `sunset`, `forest`, or `mono`. `-Sounds` accepts `on` or `off`.

These flags only update `config.json`. They do **not** recompile the DLL or refresh the hook entries in `settings.json` — if you've moved the repo, run the installer interactively and pick option 4 (Reinstall hooks) instead.

## Uninstall

```powershell
pwsh ./install.ps1 -Uninstall
```

## Customization

For most users the profile picker is enough. To hand-edit, open `hooks/config.json`:

```json
{
  "profile": "classic",
  "colors": {
    "processing": "rgb:4d/00/00",
    "stopped": "rgb:00/4d/00",
    "permission": "rgb:4a/00/80"
  },
  "sounds": {
    "stop": "stop.wav",
    "notification": "notification.wav"
  },
  "stopResetDelaySeconds": 15,
  "debug": false,
  "palettes": { "...": "..." }
}
```

- **profile** is the active palette key (`classic`, `ocean`, `sunset`, `forest`, `mono`, or `custom`); set by the installer
- **colors** are the resolved values the hooks actually read, in OSC `rgb:RR/GG/BB` format. The installer keeps these in sync with `profile`. If you set `profile` to `custom`, edit `colors` directly.
- **sounds** are paths relative to the `sounds/` directory, or absolute paths; `null` disables a sound
- **stopResetDelaySeconds** controls how long the "stopped" color shows before resetting
- **debug** enables logging to `hooks/hook-debug.log`
- **palettes** holds the curated profile definitions; you generally don't need to touch this

To swap sounds, drop `.wav` files into `~/.claude/hooks/terminal-hook-colors/sounds/` and update the config.

## How It Works

Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) run PowerShell scripts on lifecycle events. The challenge is that hook scripts run as child processes whose stdout is captured by Claude Code, so standard terminal escape sequences never reach Windows Terminal.

This project solves that by:

1. Walking the process tree (via a single bulk WMI query) to find the interactive `pwsh.exe` shell hosted by Windows Terminal
2. Using Win32 `AttachConsole` (via P/Invoke) to attach to that shell's console session
3. Writing [OSC escape sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) through the attached console:
   - **OSC 11** sets the pane background color (per-pane, not global)
   - **OSC 4;264** sets the tab strip color (Windows Terminal extension, index 264 = frame background)
   - **OSC 111 / OSC 104;264** reset colors to profile defaults

Because the sequences target a specific console session via `AttachConsole`, only the tab running that Claude instance is affected.

The Win32 API calls are defined in `ConsoleApi.cs` and compiled to a DLL at install time against your local .NET runtime. This avoids recompiling on every hook invocation and keeps startup fast. If the DLL is missing, the hooks fall back to runtime compilation automatically.

## Troubleshooting

**Colors aren't changing**: Enable debug logging by setting `"debug": true` in `config.json`, then check `hooks/hook-debug.log` after triggering a hook. The log shows the process chain, PID targeting, and write results.

**Colors change in all tabs**: You may be on an older version that doesn't support per-session OSC. Update Windows Terminal to v1.22+.

**Sounds don't play**: Ensure the `.wav` files exist in the `sounds/` directory and the filenames in `config.json` match.

**Slow color changes**: Run `pwsh ./install.ps1 -Force` to recompile the DLL. If the DLL is missing, each hook invocation pays a ~300ms compilation penalty.

## Platform Notes

This project currently supports **Windows only**. The `AttachConsole` technique is a Win32 API.

On **macOS/Linux**, the OSC escape sequences can be written directly to stdout or `/dev/tty` without the `AttachConsole` workaround, making the implementation simpler. Cross-platform support is a potential future addition.

## License

MIT
