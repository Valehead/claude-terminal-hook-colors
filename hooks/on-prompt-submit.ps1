. "$PSScriptRoot\ConsoleColor.ps1"
Start-HookWatchdog -Seconds 10
Set-TerminalColor $Config.colors.processing
Send-ColorResetCancel
