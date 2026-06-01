<#
.SYNOPSIS
    Installs, reconfigures, or uninstalls Claude Terminal Hook Colors hooks.

.DESCRIPTION
    On a fresh machine, registers hook scripts in Claude Code's settings.json
    that run directly from this repository (no files copied to user profile).

    Re-running on an already-configured machine opens a reconfigure menu so
    you can change the color profile, toggle sounds, refresh the hook
    registration, or uninstall — without disturbing other config fields.

.PARAMETER Uninstall
    Remove hooks from settings.json.

.PARAMETER Palette
    Apply a named palette non-interactively. One of:
    classic, ocean, sunset, forest, mono.

.PARAMETER Sounds
    Set sound state non-interactively. One of: on, off.

.PARAMETER SuppressWhenFocused
    Skip notification sounds while the terminal window is in the foreground.
    One of: on, off.

.PARAMETER Volume
    Notification volume from 0 (silent) to 10 (full).

.EXAMPLE
    pwsh ./install.ps1
    pwsh ./install.ps1 -Palette ocean -Sounds off
    pwsh ./install.ps1 -Sounds on -SuppressWhenFocused on -Volume 4
    pwsh ./install.ps1 -Uninstall
#>
param(
    [switch]$Uninstall,
    [ValidateSet('classic', 'ocean', 'sunset', 'forest', 'mono')]
    [string]$Palette,
    [ValidateSet('on', 'off')]
    [string]$Sounds,
    [ValidateSet('on', 'off')]
    [string]$SuppressWhenFocused,
    [ValidateRange(0, 10)]
    [Nullable[int]]$Volume
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$hooksPath = Join-Path $repoRoot 'hooks'
$claudeDir = Join-Path $HOME '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
$defaultsPath = Join-Path $hooksPath 'config.defaults.json'
$configPath = Join-Path $hooksPath 'config.json'

# Marker used to identify our hooks in settings.json
$hookMarker = 'terminal-hook-colors'

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

function Test-HooksRegistered {
    if (-not (Test-Path $settingsPath)) { return $false }
    return ((Get-Content $settingsPath -Raw) -like "*$hookMarker*")
}

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

    $submitScript = (Join-Path $hooksPath 'on-prompt-submit.ps1') -replace '\\', '/'
    $stopScript = (Join-Path $hooksPath 'on-stop.ps1') -replace '\\', '/'
    $notifyScript = (Join-Path $hooksPath 'on-notification.ps1') -replace '\\', '/'

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

function Build-ConsoleApiDll {
    $csPath = Join-Path $hooksPath 'ConsoleApi.cs'
    $dllPath = Join-Path $hooksPath 'ConsoleApi.dll'
    if (-not [System.IO.File]::Exists($csPath)) { return }
    try {
        if ([System.IO.File]::Exists($dllPath)) { Remove-Item $dllPath -Force }
        Add-Type -Path $csPath -OutputAssembly $dllPath -OutputType Library -ErrorAction Stop
        Write-Host "  Compiled ConsoleApi.dll" -ForegroundColor Green
    } catch {
        Write-Warning "  DLL compilation failed (hooks will fall back to runtime compilation): $_"
    }
}

function Update-ConsoleApiDllIfStale {
    # Self-heal: rebuild the DLL whenever the .cs source is newer or the
    # DLL is missing, so users never have to think about a stale binary
    # after pulling new code.
    $csPath = Join-Path $hooksPath 'ConsoleApi.cs'
    $dllPath = Join-Path $hooksPath 'ConsoleApi.dll'
    if (-not [System.IO.File]::Exists($csPath)) { return }
    $needsBuild = (-not [System.IO.File]::Exists($dllPath)) -or
                  ((Get-Item $csPath).LastWriteTimeUtc -gt (Get-Item $dllPath).LastWriteTimeUtc)
    if ($needsBuild) {
        Write-Host "  ConsoleApi.dll is stale, rebuilding..." -ForegroundColor DarkGray
        Build-ConsoleApiDll
    }
}

function Get-Defaults {
    Get-Content $defaultsPath -Raw | ConvertFrom-Json
}

function Get-PaletteOrder {
    # Stable, curated display order. 'custom' is appended at the end of the menu.
    return @('classic', 'ocean', 'sunset', 'forest', 'mono')
}

function ConvertTo-RgbBytes {
    # "rgb:4d/00/00" -> @(77, 0, 0). Returns $null on parse failure.
    param([string]$RgbString)
    if (-not $RgbString) { return $null }
    $hex = ($RgbString -replace '^rgb:', '') -replace '/', ''
    if ($hex.Length -ne 6) { return $null }
    try {
        return @(
            [Convert]::ToInt32($hex.Substring(0, 2), 16),
            [Convert]::ToInt32($hex.Substring(2, 2), 16),
            [Convert]::ToInt32($hex.Substring(4, 2), 16)
        )
    } catch {
        return $null
    }
}

function Format-Swatch {
    # Wraps $Text in a 24-bit ANSI background matching $RgbString, with a
    # contrasting foreground so it's legible on either dark or light hex values.
    param([string]$RgbString, [string]$Text)
    $rgb = ConvertTo-RgbBytes $RgbString
    if (-not $rgb) { return " $Text " }
    $luminance = (0.299 * $rgb[0]) + (0.587 * $rgb[1]) + (0.114 * $rgb[2])
    $fg = if ($luminance -lt 128) { '255;255;255' } else { '0;0;0' }
    $esc = [char]27
    return "$esc[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$esc[38;2;${fg}m $Text $esc[0m"
}

function Write-PaletteStateLines {
    param($Palette)
    $rows = @(
        @{ Label = 'Processing'; Hex = $Palette.processing; Meaning = 'Claude is working' },
        @{ Label = 'Permission'; Hex = $Palette.permission; Meaning = 'Claude is waiting for approval' },
        @{ Label = 'Stopped';    Hex = $Palette.stopped;    Meaning = 'Claude finished, needs your input' }
    )
    foreach ($row in $rows) {
        $label = $row.Label.PadRight(11)
        $swatch = Format-Swatch -RgbString $row.Hex -Text $row.Hex
        Write-Host ("       {0} {1}  {2}" -f $label, $swatch, $row.Meaning) -ForegroundColor DarkGray
    }
}

function Show-PalettePicker {
    param(
        [Parameter(Mandatory)] $Palettes,
        [string]$CurrentKey
    )

    $order = Get-PaletteOrder
    Write-Host ""
    Write-Host "  Choose a color profile:" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $order.Count; $i++) {
        $key = $order[$i]
        $p = $Palettes.$key
        $marker = if ($CurrentKey -eq $key) { ' (current)' } else { '' }
        $defaultMark = if ($key -eq 'classic' -and -not $CurrentKey) { ' (default)' } else { '' }
        Write-Host ("    {0}) {1}{2}{3}" -f ($i + 1), $p.name, $defaultMark, $marker) -ForegroundColor White
        Write-Host ("       {0}" -f $p.description) -ForegroundColor DarkGray
        Write-PaletteStateLines $p
        Write-Host ""
    }
    $customIdx = $order.Count + 1
    $customMarker = if ($CurrentKey -eq 'custom') { ' (current)' } else { '' }
    Write-Host ("    {0}) Custom{1}" -f $customIdx, $customMarker) -ForegroundColor White
    Write-Host "       Enter your own rgb:RR/GG/BB values for each state" -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $defaultChoice = if ($CurrentKey) {
            if ($CurrentKey -eq 'custom') { $customIdx } else { ($order.IndexOf($CurrentKey) + 1) }
        } else { 1 }
        $resp = Read-Host "  Selection [1-$customIdx, default $defaultChoice]"
        if ([string]::IsNullOrWhiteSpace($resp)) { $resp = $defaultChoice }
        if ($resp -as [int]) {
            $n = [int]$resp
            if ($n -ge 1 -and $n -le $order.Count) { return $order[$n - 1] }
            if ($n -eq $customIdx) { return 'custom' }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $customIdx." -ForegroundColor Yellow
    }
}

function Read-CustomColors {
    param($CurrentColors)
    Write-Host ""
    Write-Host "  Enter custom colors. Format: rgb:RR/GG/BB (hex pairs separated by /)." -ForegroundColor DarkGray
    Write-Host "  Press Enter to keep the value shown in brackets." -ForegroundColor DarkGray

    $proc = Read-Host "  Processing color [$($CurrentColors.processing)]"
    if (-not $proc) { $proc = $CurrentColors.processing }
    $stop = Read-Host "  Stopped color [$($CurrentColors.stopped)]"
    if (-not $stop) { $stop = $CurrentColors.stopped }
    $perm = Read-Host "  Permission color [$($CurrentColors.permission)]"
    if (-not $perm) { $perm = $CurrentColors.permission }

    return [PSCustomObject]@{
        processing = $proc
        stopped    = $stop
        permission = $perm
    }
}

function Set-PaletteOnConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$ProfileKey,
        $CustomColors
    )
    $Config | Add-Member -NotePropertyName 'profile' -NotePropertyValue $ProfileKey -Force

    if ($ProfileKey -eq 'custom') {
        $Config.colors.processing = $CustomColors.processing
        $Config.colors.stopped    = $CustomColors.stopped
        $Config.colors.permission = $CustomColors.permission
    } else {
        $p = $Config.palettes.$ProfileKey
        if (-not $p) {
            # Palette not in user's config (e.g. older config.json). Pull from defaults.
            $p = (Get-Defaults).palettes.$ProfileKey
        }
        $Config.colors.processing = $p.processing
        $Config.colors.stopped    = $p.stopped
        $Config.colors.permission = $p.permission
    }
}

function Set-SoundsOnConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [ValidateSet('on', 'off')] [string]$State
    )
    if ($State -eq 'off') {
        $Config.sounds.stop = $null
        $Config.sounds.notification = $null
    } else {
        # Only restore filenames that are currently null/empty so we don't
        # clobber user-customized .wav paths when re-enabling.
        $defaults = Get-Defaults
        if (-not $Config.sounds.stop)         { $Config.sounds.stop = $defaults.sounds.stop }
        if (-not $Config.sounds.notification) { $Config.sounds.notification = $defaults.sounds.notification }
    }
}

function Set-FocusSuppressOnConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [ValidateSet('on', 'off')] [string]$State
    )
    $value = ($State -eq 'on')
    $Config | Add-Member -NotePropertyName 'suppressSoundWhenFocused' -NotePropertyValue $value -Force
}

function Set-VolumeOnConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [double]$Volume
    )
    if ($Volume -lt 0) { $Volume = 0 }
    if ($Volume -gt 1) { $Volume = 1 }
    $Config | Add-Member -NotePropertyName 'volume' -NotePropertyValue $Volume -Force
}

function Get-CurrentFocusSuppress {
    param($Config)
    if ($Config.suppressSoundWhenFocused) { return 'on' } else { return 'off' }
}

function Get-CurrentVolume {
    # Returns the display-form volume (0-10 int) from the underlying 0.0-1.0
    # config value, or $null if no volume has been set yet so the caller can
    # apply its own default.
    param($Config)
    if ($null -eq $Config.volume) { return $null }
    return [int][math]::Round([double]$Config.volume * 10)
}

function Read-FocusSuppressChoice {
    param([string]$CurrentState)
    $defaultLabel = if ($CurrentState -eq 'on') { 'Y/n' } else { 'y/N' }
    Write-Host ""
    Write-Host "  Would you like sounds to be skipped if the window is still in focus?" -ForegroundColor DarkGray
    Write-Host "  (this will cause sounds to only play while minimized or unfocused)" -ForegroundColor DarkGray
    $resp = Read-Host "  [$defaultLabel]"
    if ([string]::IsNullOrWhiteSpace($resp)) {
        return $(if ($CurrentState -eq 'on') { 'on' } else { 'off' })
    }
    if ($resp -match '^[yY]') { return 'on' }
    return 'off'
}

function Read-VolumeChoice {
    param([Nullable[int]]$CurrentVolume)
    $defaultVolume = 10
    $effective = if ($null -ne $CurrentVolume) { [int]$CurrentVolume } else { $defaultVolume }
    Write-Host ""
    Write-Host "  What volume would you like notifications to play at?" -ForegroundColor DarkGray
    Write-Host "  (0 is silent, 10 is full volume)" -ForegroundColor DarkGray
    while ($true) {
        $resp = Read-Host "  [Current Volume: $effective]"
        if ([string]::IsNullOrWhiteSpace($resp)) { return $effective }
        $parsed = 0
        if ([int]::TryParse($resp, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 10) {
            return $parsed
        }
        Write-Host "  Enter a whole number between 0 and 10." -ForegroundColor Yellow
    }
}

function Read-SoundChoice {
    param([string]$CurrentState)
    $defaultLabel = if ($CurrentState -eq 'off') { 'y/N' } else { 'Y/n' }
    Write-Host ""
    Write-Host "  Notification sounds play when Claude finishes a task or needs" -ForegroundColor DarkGray
    Write-Host "  permission, so you can tab away without missing prompts." -ForegroundColor DarkGray
    $resp = Read-Host "  Enable notification sounds? [$defaultLabel]"
    if ([string]::IsNullOrWhiteSpace($resp)) {
        return $(if ($CurrentState -eq 'off') { 'off' } else { 'on' })
    }
    if ($resp -match '^[nN]') { return 'off' }
    return 'on'
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
    Write-Host "  Config saved" -ForegroundColor Green
}

function Get-CurrentSoundState {
    param($Config)
    if ($Config.sounds.stop -or $Config.sounds.notification) { return 'on' }
    return 'off'
}

function Show-ReconfigureMenu {
    param($Config)
    $profileLabel = if ($Config.profile) { $Config.profile } else { '(unset)' }
    $soundLabel = Get-CurrentSoundState $Config

    Write-Host ""
    Write-Host "  This installation is already configured (profile: $profileLabel, sounds: $soundLabel)." -ForegroundColor Cyan
    Write-Host "  What would you like to do?" -ForegroundColor Cyan
    Write-Host "    1) Change color profile" -ForegroundColor White
    Write-Host "    2) Sound settings (on/off, focus suppression, volume)" -ForegroundColor White
    Write-Host "    3) Reconfigure everything (profile + sounds)" -ForegroundColor White
    Write-Host "    4) Reinstall hooks (refresh settings.json + recompile DLL)" -ForegroundColor White
    Write-Host "    5) Uninstall" -ForegroundColor White
    Write-Host "    6) Cancel" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $resp = Read-Host "  Selection [1-6, default 6]"
        if ([string]::IsNullOrWhiteSpace($resp)) { return 6 }
        if ($resp -as [int]) {
            $n = [int]$resp
            if ($n -ge 1 -and $n -le 6) { return $n }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and 6." -ForegroundColor Yellow
    }
}

function Invoke-Uninstall {
    Write-Host "`nUninstalling Claude Terminal Hook Colors..." -ForegroundColor Yellow
    $settings = Read-Settings
    $settings = Remove-HookEntries $settings
    Write-Settings $settings
    Write-Host "  Hooks removed from settings.json" -ForegroundColor Green
    Write-Host "`nUninstall complete." -ForegroundColor Green
}

function Invoke-FreshInstall {
    param([string]$PaletteChoice, [string]$SoundsChoice)

    Write-Host "`nInstalling Claude Terminal Hook Colors..." -ForegroundColor Cyan
    Write-Host "  Hooks will run from: $hooksPath" -ForegroundColor DarkGray

    Copy-Item $defaultsPath $configPath -Force
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    # Palette
    if ($PaletteChoice) {
        Set-PaletteOnConfig -Config $config -ProfileKey $PaletteChoice
        Write-Host "  Profile: $PaletteChoice" -ForegroundColor DarkGray
    } else {
        $key = Show-PalettePicker -Palettes $config.palettes -CurrentKey $null
        $custom = $null
        if ($key -eq 'custom') {
            $custom = Read-CustomColors -CurrentColors $config.colors
        }
        Set-PaletteOnConfig -Config $config -ProfileKey $key -CustomColors $custom
    }

    # Sounds
    $soundsState = $null
    if ($SoundsChoice) {
        Set-SoundsOnConfig -Config $config -State $SoundsChoice
        $soundsState = $SoundsChoice
        Write-Host "  Sounds: $SoundsChoice" -ForegroundColor DarkGray
    } else {
        $soundsState = Read-SoundChoice -CurrentState 'on'
        Set-SoundsOnConfig -Config $config -State $soundsState
        Write-Host "  Sounds $soundsState" -ForegroundColor DarkGray
    }

    # Focus suppression
    if ($SuppressWhenFocused) {
        Set-FocusSuppressOnConfig -Config $config -State $SuppressWhenFocused
        Write-Host "  Suppress when focused: $SuppressWhenFocused" -ForegroundColor DarkGray
    } elseif ($soundsState -eq 'on') {
        $sup = Read-FocusSuppressChoice -CurrentState 'off'
        Set-FocusSuppressOnConfig -Config $config -State $sup
        Write-Host "  Suppress when focused: $sup" -ForegroundColor DarkGray
    } else {
        Set-FocusSuppressOnConfig -Config $config -State 'off'
    }

    # Volume (UI is 0-10 int, stored as 0.0-1.0 double)
    if ($null -ne $Volume) {
        Set-VolumeOnConfig -Config $config -Volume ([double]$Volume / 10.0)
        Write-Host "  Volume: $Volume" -ForegroundColor DarkGray
    } elseif ($soundsState -eq 'on') {
        $vol = Read-VolumeChoice -CurrentVolume 10
        Set-VolumeOnConfig -Config $config -Volume ([double]$vol / 10.0)
        Write-Host "  Volume: $vol" -ForegroundColor DarkGray
    } else {
        Set-VolumeOnConfig -Config $config -Volume 1.0
    }

    Save-Config $config
    Build-ConsoleApiDll

    $settings = Read-Settings
    $settings = Remove-HookEntries $settings
    $settings = Add-HookEntries $settings
    Write-Settings $settings
    Write-Host "  Hooks added to settings.json" -ForegroundColor Green

    Write-InstallSummary $config
}

function Invoke-Reconfigure {
    param([string]$PaletteChoice, [string]$SoundsChoice)

    Update-ConsoleApiDllIfStale

    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    # Backfill palettes if user is on an old config.json that lacks them.
    if (-not $config.palettes) {
        $config | Add-Member -NotePropertyName 'palettes' -NotePropertyValue (Get-Defaults).palettes -Force
    }

    # Non-interactive path: apply flags silently.
    if ($PaletteChoice -or $SoundsChoice -or $SuppressWhenFocused -or ($null -ne $Volume)) {
        if ($PaletteChoice) {
            Set-PaletteOnConfig -Config $config -ProfileKey $PaletteChoice
            Write-Host "  Profile changed to: $PaletteChoice" -ForegroundColor Green
        }
        if ($SoundsChoice) {
            Set-SoundsOnConfig -Config $config -State $SoundsChoice
            Write-Host "  Sounds set to: $SoundsChoice" -ForegroundColor Green
        }
        if ($SuppressWhenFocused) {
            Set-FocusSuppressOnConfig -Config $config -State $SuppressWhenFocused
            Write-Host "  Suppress when focused: $SuppressWhenFocused" -ForegroundColor Green
        }
        if ($null -ne $Volume) {
            Set-VolumeOnConfig -Config $config -Volume ([double]$Volume / 10.0)
            Write-Host "  Volume: $Volume" -ForegroundColor Green
        }
        Save-Config $config
        Write-InstallSummary -Config $config -Header 'Reconfigure complete.'
        return
    }

    $choice = Show-ReconfigureMenu $config
    switch ($choice) {
        1 {
            $key = Show-PalettePicker -Palettes $config.palettes -CurrentKey $config.profile
            $custom = $null
            if ($key -eq 'custom') {
                $custom = Read-CustomColors -CurrentColors $config.colors
            }
            Set-PaletteOnConfig -Config $config -ProfileKey $key -CustomColors $custom
            Save-Config $config
            Write-InstallSummary -Config $config -Header 'Reconfigure complete.'
        }
        2 {
            $state = Read-SoundChoice -CurrentState (Get-CurrentSoundState $config)
            Set-SoundsOnConfig -Config $config -State $state
            if ($state -eq 'on') {
                $sup = Read-FocusSuppressChoice -CurrentState (Get-CurrentFocusSuppress $config)
                Set-FocusSuppressOnConfig -Config $config -State $sup
                $vol = Read-VolumeChoice -CurrentVolume (Get-CurrentVolume $config)
                Set-VolumeOnConfig -Config $config -Volume ([double]$vol / 10.0)
            }
            Save-Config $config
            Write-InstallSummary -Config $config -Header 'Reconfigure complete.'
        }
        3 {
            $key = Show-PalettePicker -Palettes $config.palettes -CurrentKey $config.profile
            $custom = $null
            if ($key -eq 'custom') {
                $custom = Read-CustomColors -CurrentColors $config.colors
            }
            Set-PaletteOnConfig -Config $config -ProfileKey $key -CustomColors $custom
            $state = Read-SoundChoice -CurrentState (Get-CurrentSoundState $config)
            Set-SoundsOnConfig -Config $config -State $state
            if ($state -eq 'on') {
                $sup = Read-FocusSuppressChoice -CurrentState (Get-CurrentFocusSuppress $config)
                Set-FocusSuppressOnConfig -Config $config -State $sup
                $vol = Read-VolumeChoice -CurrentVolume (Get-CurrentVolume $config)
                Set-VolumeOnConfig -Config $config -Volume ([double]$vol / 10.0)
            }
            Save-Config $config
            Write-InstallSummary -Config $config -Header 'Reconfigure complete.'
        }
        4 {
            Build-ConsoleApiDll
            $settings = Read-Settings
            $settings = Remove-HookEntries $settings
            $settings = Add-HookEntries $settings
            Write-Settings $settings
            Write-Host "  Hooks refreshed in settings.json" -ForegroundColor Green
        }
        5 {
            Invoke-Uninstall
            return
        }
        6 {
            Write-Host "  Cancelled. No changes made." -ForegroundColor DarkGray
            return
        }
    }
}

function Write-InstallSummary {
    param($Config, [string]$Header = 'Install complete!')
    $profileLabel = if ($Config.profile) { $Config.profile } else { 'classic' }
    $soundLabel = Get-CurrentSoundState $Config
    $focusLabel = Get-CurrentFocusSuppress $Config
    $volumeValue = Get-CurrentVolume $Config
    $volumeLabel = if ($null -ne $volumeValue) { "$volumeValue" } else { '10 (default)' }

    Write-Host "`n$Header" -ForegroundColor Green
    Write-Host @"

  Hooks run directly from this repo. Do not move or delete it.

  Profile:    $profileLabel
  Processing: $($Config.colors.processing)
  Stopped:    $($Config.colors.stopped)  (resets after $($Config.stopResetDelaySeconds)s)
  Permission: $($Config.colors.permission)
  Sounds:     $soundLabel  (suppress when focused: $focusLabel, volume: $volumeLabel)

  Reconfigure: pwsh $repoRoot\install.ps1
  Uninstall:   pwsh $repoRoot\install.ps1 -Uninstall
"@ -ForegroundColor DarkGray
}

# --- Main ---

if (-not (Test-Prerequisites)) { exit 1 }

if ($Uninstall) {
    Invoke-Uninstall
    exit 0
}

$alreadyInstalled = (Test-Path $configPath) -and (Test-HooksRegistered)

if ($alreadyInstalled) {
    Invoke-Reconfigure -PaletteChoice $Palette -SoundsChoice $Sounds
} else {
    Invoke-FreshInstall -PaletteChoice $Palette -SoundsChoice $Sounds
}
