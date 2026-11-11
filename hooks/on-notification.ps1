. "$PSScriptRoot\ConsoleColor.ps1"
Start-HookWatchdog -Seconds 20
Set-TerminalColor $Config.colors.permission
Play-HookSound -SoundName 'notification' -Sync
