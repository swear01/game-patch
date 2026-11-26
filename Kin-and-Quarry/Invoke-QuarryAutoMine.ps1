[CmdletBinding()]
param([string]$Directory = $env:QUARRY_CONTROL_DIR)

$ErrorActionPreference = 'Stop'
$client = Join-Path $PSScriptRoot 'Invoke-QuarryControl.ps1'
$pointer = Join-Path $env:APPDATA 'Godot/app_userdata/Kin and Quarry/quarry-control-path.txt'
$lock = $null
$lastMessage = ''
$autoMineToken = [guid]::NewGuid().ToString('N')
$hasFastLease = $false
$clock = [Diagnostics.Stopwatch]::StartNew()
$legacyUntil = 0

function Show-State([string]$Message) {
    if ($Message -ne $script:lastMessage) {
        Write-Host $Message
        $script:lastMessage = $Message
    }
}

if (!(Test-Path -LiteralPath $client -PathType Leaf)) {
    throw 'Keep Invoke-QuarryControl.ps1 in the same folder as this script.'
}

Write-Host 'Kin and Quarry auto-mining. Press Ctrl+C or close this window to stop.'
try {
    while (!$lock) {
        try {
            $path = $Directory
            if (!$path) { $path = (Get-Content -LiteralPath $pointer -Raw).Trim() }
            if (!$path) { throw 'The control channel path is empty.' }
            $mailbox = (Resolve-Path -LiteralPath $path).ProviderPath
        } catch {
            Show-State "Waiting for the game control folder: $($_.Exception.Message)"
            Start-Sleep -Seconds 1
            continue
        }

        try {
            $lock = [IO.File]::Open((Join-Path $mailbox 'auto-mine.lock'), 'OpenOrCreate', 'Write', 'None')
        } catch {
            if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -in 32, 33) {
                Write-Host 'Auto-mining is already running for this game.'
                return
            }
            throw
        }
    }

    while ($true) {
        $tryingFast = $clock.ElapsedMilliseconds -ge $legacyUntil
        $delay = if ($tryingFast) { 250 } else { 0 }
        try {
            if ($tryingFast) {
                $result = & $client -Directory $mailbox -Action auto_mine_heartbeat -AutoMineToken $autoMineToken -TimeoutSeconds 1 -PollMilliseconds 15
                if (!$result.ok -and $result.reason -eq 'unsupported action') {
                    # The earlier patch keeps working; re-check after a game restart.
                    $legacyUntil = $clock.ElapsedMilliseconds + 3000
                    $hasFastLease = $false
                    continue
                }
                if ($result.ok) { $hasFastLease = $true }
            } else {
                $result = & $client -Directory $mailbox -Action advance_day -TimeoutSeconds 2 -PollMilliseconds 15
            }
            if (!$result.ok) {
                if (!$tryingFast -and $result.reason -eq 'unsupported action') {
                    Show-State 'This version of the game control does not support auto-mining. Update the control patch and restart the game.'
                    $delay = 2000
                } else {
                    Show-State "Waiting for the game: $($result.reason)."
                    $delay = 500
                }
            } else {
                switch ($result.state) {
                    'load_save' { Show-State 'Load the save you want to mine in Steam.'; $delay = 250 }
                    'mining' { Show-State "Mining day $($result.day)." }
                    'reward' { Show-State 'Accepted an artifact reward.' }
                    'starting' { Show-State "Start requested for day $($result.day). Check the game if a confirmation appears." }
                    'started' { Show-State "Starting day $($result.day)." }
                    'waiting' { Show-State "Waiting for day $($result.day) to become available." }
                    default { Show-State "Waiting for the game: $($result.state)."; $delay = 500 }
                }
            }
        } catch {
            Show-State "Waiting for the game control channel: $($_.Exception.Message)"
            $delay = 1000
        }
        if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
    }
} finally {
    try {
        if ($hasFastLease) {
            try {
                & $client -Directory $mailbox -Action auto_mine_stop -AutoMineToken $autoMineToken -TimeoutSeconds 1 -PollMilliseconds 15 | Out-Null
            } catch {
                # The last lease expires on its own if the game cannot reply.
            }
        }
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}
