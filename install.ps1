<#
.SYNOPSIS
    Installs or uninstalls Claude Terminal Colors hooks.

.DESCRIPTION
    Copies hook scripts and sound files to the install location, then merges
    hook configuration into Claude Code's settings.json.

.PARAMETER Uninstall
    Remove hooks from settings.json and optionally delete installed files.

.PARAMETER Force
    Overwrite existing files without prompting.

.PARAMETER InstallPath
    Override the default install location (~/.claude/hooks/terminal-colors).

.EXAMPLE
    pwsh ./install.ps1
    pwsh ./install.ps1 -Uninstall
    pwsh ./install.ps1 -InstallPath "D:\my-hooks\terminal-colors"
#>
param(
    [switch]$Uninstall,
    [switch]$Force,
    [string]$InstallPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$claudeDir = Join-Path $HOME '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'

if (-not $InstallPath) {
    $InstallPath = Join-Path $claudeDir 'hooks' 'terminal-colors'
}

$hooksInstallPath = Join-Path $InstallPath 'hooks'
$soundsInstallPath = Join-Path $InstallPath 'sounds'

# Marker used to identify our hooks in settings.json
$hookMarker = 'terminal-colors'

function Test-Prerequisites {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Error "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
        return $false
    }
    if (-not (Test-Path $settingsPath)) {
        Write-Error "Claude Code settings not found at $settingsPath. Run 'claude' at least once first."
        return $false
    }
    $wt = Get-AppxPackage Microsoft.WindowsTerminal* -ErrorAction SilentlyContinue
    if (-not $wt) {
        Write-Warning "Windows Terminal not detected. These hooks are designed for Windows Terminal."
    }
    return $true
}

function Read-Settings {
    Get-Content $settingsPath -Raw | ConvertFrom-Json
}

function Write-Settings {
    param($Settings)
    $backupPath = "$settingsPath.bak"
    Copy-Item $settingsPath $backupPath -Force
    $Settings | ConvertTo-Json -Depth 20 | Set-Content $settingsPath -Encoding UTF8
    Write-Host "  Backup saved to $backupPath" -ForegroundColor DarkGray
}

$script:HookTypes = @('UserPromptSubmit', 'Stop', 'Notification')

function Remove-HookEntries {
    param($Settings)
    if (-not $Settings.hooks) { return $Settings }

    foreach ($type in $script:HookTypes) {
        $entries = $Settings.hooks.$type
        if (-not $entries) { continue }

        $filtered = @()
        foreach ($entry in $entries) {
            $keep = $true
            foreach ($hook in $entry.hooks) {
                if ($hook.command -and $hook.command -like "*$hookMarker*") {
                    $keep = $false
                    break
                }
            }
            if ($keep) { $filtered += $entry }
        }

        if ($filtered.Count -eq 0) {
            $Settings.hooks.PSObject.Properties.Remove($type)
        } else {
            $Settings.hooks.$type = $filtered
        }
    }

    return $Settings
}

function Add-HookEntries {
    param($Settings)

    if (-not $Settings.hooks) {
        $Settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }

    $submitScript = (Join-Path $hooksInstallPath 'on-prompt-submit.ps1') -replace '\\', '/'
    $stopScript = (Join-Path $hooksInstallPath 'on-stop.ps1') -replace '\\', '/'
    $notifyScript = (Join-Path $hooksInstallPath 'on-notification.ps1') -replace '\\', '/'

    $hookDefs = @{
        UserPromptSubmit = @{
            command = "pwsh -NoProfile -File `"$submitScript`""
            async   = $false
            matcher = $null
        }
        Stop = @{
            command = "pwsh -NoProfile -File `"$stopScript`""
            async   = $true
            matcher = $null
        }
        Notification = @{
            command = "pwsh -NoProfile -File `"$notifyScript`""
            async   = $true
            matcher = 'permission_prompt'
        }
    }

    foreach ($type in $hookDefs.Keys) {
        $def = $hookDefs[$type]
        $hookObj = [PSCustomObject]@{
            type    = 'command'
            command = $def.command
            shell   = 'powershell'
        }
        if ($def.async) {
            $hookObj | Add-Member -NotePropertyName 'async' -NotePropertyValue $true
        }

        $entryObj = [PSCustomObject]@{
            hooks = @($hookObj)
        }
        if ($def.matcher) {
            $entryObj | Add-Member -NotePropertyName 'matcher' -NotePropertyValue $def.matcher
        }

        $existing = $Settings.hooks.$type
        if ($existing) {
            $Settings.hooks.$type = @() + @($existing) + @($entryObj)
        } else {
            $Settings.hooks | Add-Member -NotePropertyName $type -NotePropertyValue @($entryObj) -Force
        }
    }

    return $Settings
}

# --- Main ---

if (-not (Test-Prerequisites)) { exit 1 }

if ($Uninstall) {
    Write-Host "`nUninstalling Claude Terminal Colors..." -ForegroundColor Yellow

    $settings = Read-Settings
    $settings = Remove-HookEntries $settings
    Write-Settings $settings
    Write-Host "  Hooks removed from settings.json" -ForegroundColor Green

    if (Test-Path $InstallPath) {
        if ($Force) {
            Remove-Item $InstallPath -Recurse -Force
            Write-Host "  Deleted $InstallPath" -ForegroundColor Green
        } else {
            $response = Read-Host "  Delete installed files at $InstallPath? [y/N]"
            if ($response -eq 'y') {
                Remove-Item $InstallPath -Recurse -Force
                Write-Host "  Deleted $InstallPath" -ForegroundColor Green
            } else {
                Write-Host "  Files kept at $InstallPath" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "`nUninstall complete." -ForegroundColor Green
    exit 0
}

# --- Install ---

Write-Host "`nInstalling Claude Terminal Colors..." -ForegroundColor Cyan
Write-Host "  Install path: $InstallPath" -ForegroundColor DarkGray

# Copy files
if ((Test-Path $hooksInstallPath) -and -not $Force) {
    $response = Read-Host "  Files already exist at $InstallPath. Overwrite? [y/N]"
    if ($response -ne 'y') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
}

New-Item -ItemType Directory -Path $hooksInstallPath -Force | Out-Null
New-Item -ItemType Directory -Path $soundsInstallPath -Force | Out-Null

Copy-Item (Join-Path $repoRoot 'hooks' '*') $hooksInstallPath -Force
Copy-Item (Join-Path $repoRoot 'sounds' '*') $soundsInstallPath -Force
Write-Host "  Copied hooks and sounds" -ForegroundColor Green

# Configuration prompts
$configPath = Join-Path $hooksInstallPath 'config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

Write-Host ""
$enableSounds = Read-Host "  Enable notification sounds? [Y/n]"
if ($enableSounds -eq 'n') {
    $config.sounds.stop = $null
    $config.sounds.notification = $null
    Write-Host "  Sounds disabled" -ForegroundColor DarkGray
} else {
    Write-Host "  Sounds enabled" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Default colors (enter to keep, or provide rgb:RR/GG/BB):" -ForegroundColor DarkGray
Write-Host "    Hex to OSC format: #4d0000 becomes rgb:4d/00/00" -ForegroundColor DarkGray

$customProcessing = Read-Host "  Processing color [dark red: $($config.colors.processing)]"
if ($customProcessing) { $config.colors.processing = $customProcessing }

$customStopped = Read-Host "  Stopped color    [dark green: $($config.colors.stopped)]"
if ($customStopped) { $config.colors.stopped = $customStopped }

$customPermission = Read-Host "  Permission color [purple: $($config.colors.permission)]"
if ($customPermission) { $config.colors.permission = $customPermission }

$config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
Write-Host "  Config saved" -ForegroundColor Green

# Compile ConsoleApi DLL for faster hook startup
$csPath = Join-Path $hooksInstallPath 'ConsoleApi.cs'
$dllPath = Join-Path $hooksInstallPath 'ConsoleApi.dll'
if ([System.IO.File]::Exists($csPath)) {
    try {
        Add-Type -Path $csPath -OutputAssembly $dllPath -OutputType Library -ErrorAction Stop
        Write-Host "  Compiled ConsoleApi.dll" -ForegroundColor Green
    } catch {
        Write-Warning "  DLL compilation failed (hooks will fall back to runtime compilation): $_"
    }
}

# Update settings.json
$settings = Read-Settings
$settings = Remove-HookEntries $settings
$settings = Add-HookEntries $settings
Write-Settings $settings
Write-Host "  Hooks added to settings.json" -ForegroundColor Green

Write-Host "`nInstall complete!" -ForegroundColor Green
Write-Host @"

  Colors:
    Processing  = dark red ($($settings.hooks ? 'active' : 'check settings'))
    Stopped     = dark green (resets after 15s)
    Permission  = purple

  Customize:  Edit $hooksInstallPath\config.json
  Uninstall:  pwsh $repoRoot\install.ps1 -Uninstall
"@ -ForegroundColor DarkGray
