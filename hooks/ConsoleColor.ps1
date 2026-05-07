# Shared library for Claude Code terminal color hooks
# Uses pre-compiled DLL and bulk WMI query for fast startup.

$script:HookRoot = $PSScriptRoot
$script:SoundsRoot = Join-Path (Split-Path $script:HookRoot) 'sounds'
$script:Config = Get-Content (Join-Path $script:HookRoot 'config.json') -Raw | ConvertFrom-Json
$script:CachedTargetPid = $null
$script:Esc = [char]27
$script:Bel = [char]7
$script:INVALID_HANDLE = [IntPtr]::new(-1)

if (-not ([System.Management.Automation.PSTypeName]'ConsoleApi').Type) {
    $dllPath = Join-Path $script:HookRoot 'ConsoleApi.dll'
    if ([System.IO.File]::Exists($dllPath)) {
        Add-Type -Path $dllPath
    } else {
        Add-Type -TypeDefinition ([System.IO.File]::ReadAllText((Join-Path $script:HookRoot 'ConsoleApi.cs')))
    }
}

function Write-HookDebug {
    param([string]$Message)
    if ($script:Config.debug) {
        $logPath = Join-Path $script:HookRoot 'hook-debug.log'
        Add-Content $logPath "$(Get-Date -Format 'HH:mm:ss') $Message"
    }
}

function Find-TargetConsolePid {
    $allProcs = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name
    $procMap = @{}
    foreach ($proc in $allProcs) { $procMap[[int]$proc.ProcessId] = $proc }

    $p = $PID
    $chain = @()
    while ($p -and $p -ne 0 -and $procMap.ContainsKey([int]$p)) {
        $entry = $procMap[[int]$p]
        $chain += [PSCustomObject]@{ ProcessId = [int]$entry.ProcessId; Name = $entry.Name; ParentId = [int]$entry.ParentProcessId }
        $p = $entry.ParentProcessId
    }

    Write-HookDebug "[find-pid] Chain: $(($chain | ForEach-Object { "$($_.Name)(PID $($_.ProcessId))" }) -join ' -> ')"

    for ($i = 0; $i -lt $chain.Count; $i++) {
        if (($i + 1) -lt $chain.Count -and $chain[$i + 1].Name -eq 'WindowsTerminal.exe') {
            Write-HookDebug "[find-pid] Found shell under WindowsTerminal: $($chain[$i].Name) ($($chain[$i].ProcessId))"
            return $chain[$i].ProcessId
        }
    }

    for ($i = $chain.Count - 1; $i -ge 0; $i--) {
        if ($chain[$i].Name -eq 'pwsh.exe') {
            Write-HookDebug "[find-pid] Fallback to outermost pwsh: $($chain[$i].ProcessId)"
            return $chain[$i].ProcessId
        }
    }

    Write-HookDebug "[find-pid] No target found"
    return $null
}

function Get-TargetConsolePid {
    if (-not $script:CachedTargetPid) {
        $script:CachedTargetPid = Find-TargetConsolePid
    }
    return $script:CachedTargetPid
}

function Write-OscToConsole {
    param([string]$Payload)
    $targetPid = Get-TargetConsolePid
    if (-not $targetPid) { return $false }

    [void][ConsoleApi]::FreeConsole()
    $attached = [ConsoleApi]::AttachConsole([uint32]$targetPid)
    if (-not $attached) {
        Write-HookDebug "[osc] AttachConsole($targetPid) failed: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        return $false
    }

    $handle = [ConsoleApi]::CreateFile("CONOUT$", 0x40000000, 0x00000002, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($handle -eq $script:INVALID_HANDLE) {
        Write-HookDebug "[osc] CreateFile CONOUT$ failed: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        return $false
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $written = [uint32]0
    [void][ConsoleApi]::WriteFile($handle, $bytes, [uint32]$bytes.Length, [ref]$written, [IntPtr]::Zero)
    [void][ConsoleApi]::CloseHandle($handle)

    Write-HookDebug "[osc] Wrote $written bytes to PID $targetPid"
    return $true
}

function Set-TerminalColor {
    param([string]$Color)
    [void](Write-OscToConsole "$($script:Esc)]11;${Color}$($script:Bel)$($script:Esc)]4;264;${Color}$($script:Bel)")
}

function Reset-TerminalColor {
    [void](Write-OscToConsole "$($script:Esc)]111$($script:Bel)$($script:Esc)]104;264$($script:Bel)")
}

function Get-ResetCancelEventName {
    $targetPid = Get-TargetConsolePid
    if (-not $targetPid) { return $null }
    return "Claude-Color-Reset-$targetPid"
}

function Wait-ColorResetCancellable {
    param([int]$TimeoutMs)

    $name = Get-ResetCancelEventName
    if (-not $name) {
        Write-HookDebug "[wait] No target PID; falling back to plain sleep"
        Start-Sleep -Milliseconds $TimeoutMs
        return $false
    }

    $createdNew = $false
    $evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $name, [ref]$createdNew)
    try {
        [void]$evt.Reset()
        $signaled = $evt.WaitOne($TimeoutMs)
        Write-HookDebug "[wait] event '$name' signaled=$signaled (createdNew=$createdNew)"
        return $signaled
    } finally {
        $evt.Dispose()
    }
}

function Send-ColorResetCancel {
    $name = Get-ResetCancelEventName
    if (-not $name) {
        Write-HookDebug "[signal] No target PID; skipping signal"
        return
    }

    $evt = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting($name, [ref]$evt)) {
        try {
            [void]$evt.Set()
            Write-HookDebug "[signal] set event '$name'"
        } finally {
            $evt.Dispose()
        }
    } else {
        Write-HookDebug "[signal] no waiter for '$name'"
    }
}

function Play-HookSound {
    param(
        [string]$SoundName,
        [switch]$Sync
    )
    $soundFile = $script:Config.sounds.$SoundName
    if (-not $soundFile) { return }

    if (-not [System.IO.Path]::IsPathRooted($soundFile)) {
        $soundFile = Join-Path $script:SoundsRoot $soundFile
    }
    if (-not [System.IO.File]::Exists($soundFile)) {
        Write-HookDebug "[sound] File not found: $soundFile"
        return
    }

    $player = New-Object System.Media.SoundPlayer $soundFile
    if ($Sync) { $player.PlaySync() } else { $player.Play() }
}
