. "$PSScriptRoot\ConsoleColor.ps1"
Set-TerminalColor $Config.colors.stopped
Play-HookSound -SoundName 'stop'
$cancelled = Wait-ColorResetCancellable -TimeoutMs ($Config.stopResetDelaySeconds * 1000)
if (-not $cancelled) { Reset-TerminalColor }
