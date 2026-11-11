. "$PSScriptRoot\ConsoleColor.ps1"
Start-HookWatchdog -Seconds ($Config.stopResetDelaySeconds + 30)
Set-TerminalColor $Config.colors.stopped
Play-HookSound -SoundName 'stop'
$cancelled = Wait-ColorResetCancellable -TimeoutMs ($Config.stopResetDelaySeconds * 1000)
if (-not $cancelled) { Reset-TerminalColor }
