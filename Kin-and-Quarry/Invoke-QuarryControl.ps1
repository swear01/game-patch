[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('status', 'open_save_picker', 'load_slot', 'start_day', 'acknowledge_artifact', 'advance_day', 'camera_autopan_off', 'save_and_close', 'auto_mine_heartbeat', 'auto_mine_stop')]
    [string]$Action,
    [ValidateRange(1, 3)]
    [int]$Slot = 1,
    [string]$Directory = $env:QUARRY_CONTROL_DIR,
    [int]$TimeoutSeconds = 8,
    [ValidateRange(15, 200)][int]$PollMilliseconds = 100,
    [ValidatePattern('^[0-9a-f]{32}$')][string]$AutoMineToken
)

$ErrorActionPreference = 'Stop'
if (!$Directory) {
    $pointer = Join-Path $env:APPDATA 'Godot/app_userdata/Kin and Quarry/quarry-control-path.txt'
    $Directory = (Get-Content -LiteralPath $pointer -Raw).Trim()
}
$Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
$request = Join-Path $Directory request.json
$response = Join-Path $Directory response.json
$id = [guid]::NewGuid().ToString('N')
$temp = Join-Path $Directory "$id.tmp"
$message = @{ id = $id; action = $Action; slot = $Slot }
if ($Action -in @('auto_mine_heartbeat', 'auto_mine_stop')) {
    if (!$AutoMineToken) { throw "The '$Action' action requires an Auto Mining token." }
    $message.auto_mine_token = $AutoMineToken
}
$watch = [Diagnostics.Stopwatch]::StartNew()
$lease = $null
$published = $false
try {
    while (!$lease -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $lease = [IO.File]::Open((Join-Path $Directory 'client.lock'), 'OpenOrCreate', 'Write', 'None')
        } catch {
            if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -notin 32, 33) { throw }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
    if (!$lease) { throw 'The game control folder is busy.' }
    if ($Action -eq 'advance_day') {
        $message.expires_unix_ms = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds - $watch.Elapsed.TotalSeconds).ToUnixTimeMilliseconds()
    } elseif ($Action -eq 'auto_mine_heartbeat') {
        $message.expires_unix_ms = [DateTimeOffset]::UtcNow.AddMilliseconds(800).ToUnixTimeMilliseconds()
    }
    [IO.File]::WriteAllText($temp, ($message | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    while (!$published -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            [IO.File]::Move($temp, $request)
            $published = $true
        } catch {
            if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -notin 32, 33, 80, 183) { throw }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $response) {
            try {
                $result = [IO.File]::ReadAllText($response) | ConvertFrom-Json
                if ($result.id -eq $id) { return $result }
            } catch {
                $readFailure = $_.Exception.GetBaseException()
                if ($readFailure -isnot [System.IO.IOException] -and $readFailure -isnot [System.UnauthorizedAccessException]) { throw }
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    throw "No reply for '$Action'; check that the game is running with the control channel enabled."
} finally {
    try {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
        if ($published -and (Test-Path -LiteralPath $request)) {
            $pending = Get-Content -LiteralPath $request -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($pending.id -eq $id) { Remove-Item -LiteralPath $request -ErrorAction SilentlyContinue }
        }
    } finally {
        if ($lease) { $lease.Dispose() }
    }
}
