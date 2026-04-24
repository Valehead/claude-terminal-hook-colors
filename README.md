# Claude Terminal Hook Colors

Visual feedback for Claude Code sessions in Windows Terminal. Each tab independently changes color based on Claude's state, so you can tell at a glance which tabs need your attention.

| State | Color | Meaning |
|-------|-------|---------|
| Processing | Dark red | Claude is working |
| Stopped | Dark green | Claude finished, needs your input |
| Permission prompt | Purple | Claude is waiting for permission |

Colors reset to your default terminal theme after 15 seconds (configurable).

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

This copies the hook scripts to `~/.claude/hooks/terminal-hook-colors/`, compiles a native DLL for faster startup, and adds the hook configuration to your Claude Code settings.

## Uninstall

```powershell
pwsh ./install.ps1 -Uninstall
```

## Customization

Edit `~/.claude/hooks/terminal-hook-colors/hooks/config.json`:

```json
{
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
  "debug": false
}
```

- **Colors** use OSC `rgb:RR/GG/BB` format (hex pairs separated by `/`)
- **Sounds** are paths relative to the `sounds/` directory, or absolute paths
- **stopResetDelaySeconds** controls how long the green "stopped" color shows before resetting
- **debug** enables logging to `hooks/hook-debug.log`

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
