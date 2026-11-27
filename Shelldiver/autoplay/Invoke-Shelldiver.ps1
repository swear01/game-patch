[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')]
    [string]$Action,

    [string]$ParametersJson = '{}',

    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'
$Action = $Action.ToLowerInvariant()
$Mailbox = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Mailbox)
$timer = [Diagnostics.Stopwatch]::StartNew()
$ackPollMs = 8
$requestedPollMs = 0
if ([int]::TryParse($env:SHELLDIVER_ACK_POLL_MS, [ref]$requestedPollMs) -and $requestedPollMs -in 8, 25) { $ackPollMs = $requestedPollMs }

function Read-MailboxJson([string]$Path) {
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    } catch {
        $errorCode = $_.Exception.GetBaseException().HResult -band 0xFFFF
        if ($errorCode -in 2, 3, 32, 33) { return }
        throw
    }
    try {
        $reader = [IO.StreamReader]::new($stream)
        try { $contents = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
    return (ConvertFrom-Json -InputObject $contents)
}

$sessionStopPath = $env:SHELLDIVER_SESSION_STOP_PATH
$sessionStartedTicks = 0L
$watchForStop = $Action -ne 'stop' -and $sessionStopPath -and
    [long]::TryParse($env:SHELLDIVER_SESSION_STARTED_TICKS, [ref]$sessionStartedTicks)

function Assert-SessionNotStopped {
    if (!$watchForStop) { return }
    $signal = Read-MailboxJson $sessionStopPath
    if ($signal -and $signal.requestedTicks -ge $sessionStartedTicks) {
        throw [OperationCanceledException]::new('Shelldiver session stop requested.')
    }
}

Assert-SessionNotStopped
if ($Action -eq 'snapshot') {
    $snapshotPath = Join-Path $Mailbox 'snapshot.json'
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Assert-SessionNotStopped
        $snapshot = Read-MailboxJson $snapshotPath
        if ($null -ne $snapshot) { return $snapshot }
        Start-Sleep -Milliseconds 25
    }
    throw "No Shelldiver snapshot appeared in '$Mailbox' within $TimeoutSeconds seconds."
}

$parameters = ConvertFrom-Json -InputObject $ParametersJson
if (!$ParametersJson.TrimStart().StartsWith('{') -or $parameters -isnot [pscustomobject]) {
    throw '-ParametersJson must contain a JSON object.'
}

$hostStartedUtc = [DateTime]::UtcNow
$requestId = [guid]::NewGuid().ToString('N')
$request = @{
    id = $requestId
    action = $Action
    parameters = $parameters
}
$requestJson = ConvertTo-Json -InputObject $request -Depth 20 -Compress

$null = [IO.Directory]::CreateDirectory($Mailbox)
$lockPath = Join-Path $Mailbox 'client.lock'
$commandPath = Join-Path $Mailbox 'command.json'
$resultPath = Join-Path $Mailbox 'result.json'
$temporaryPath = Join-Path $Mailbox "command-$requestId.tmp"
$lease = $null

try {
    while (!$lease -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Assert-SessionNotStopped
        try {
            $lease = [IO.File]::Open($lockPath, 'OpenOrCreate', 'Write', 'None')
        } catch {
            $errorCode = $_.Exception.GetBaseException().HResult -band 0xFFFF
            if ($errorCode -notin 32, 33) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
    if (!$lease) { throw "Timed out waiting for another Shelldiver CLI command to finish." }

    [IO.File]::WriteAllText($temporaryPath, $requestJson, [Text.UTF8Encoding]::new($false))
    $submitted = $false
    $clearedPriorResponse = $false
    while (!$submitted -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Assert-SessionNotStopped
        try {
            if (!$clearedPriorResponse -and ![IO.File]::Exists($commandPath)) {
                # The previous reply belongs to a different request. An empty destination also avoids a Windows rename/read race.
                [IO.File]::Delete($resultPath)
                $clearedPriorResponse = $true
            }
            [IO.File]::Move($temporaryPath, $commandPath)
            $hostQueuedUtc = [DateTime]::UtcNow
            $queuedMs = $timer.Elapsed.TotalMilliseconds
            $submitted = $true
        } catch {
            $errorCode = $_.Exception.GetBaseException().HResult -band 0xFFFF
            if ($errorCode -notin 5, 32, 33, 80, 183) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
    if (!$submitted) {
        throw "Timed out queuing '$Action'. Shelldiver has an outstanding command."
    }

    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Assert-SessionNotStopped
        $result = if ([IO.File]::Exists($resultPath)) { Read-MailboxJson $resultPath }
        if ($result.id -ceq $requestId) {
            if ($result.ok -isnot [bool]) {
                throw "Invalid Shelldiver result for '$Action' ($requestId)."
            }
            if (!$result.ok) {
                throw "Shelldiver rejected '$Action' ($requestId). $($result.error)"
            }
            $acknowledgedMs = $timer.Elapsed.TotalMilliseconds
            $result | Add-Member -NotePropertyMembers @{
                hostPid = $PID
                hostQueueToAckMs = [Math]::Round($acknowledgedMs - $queuedMs, 3)
                ackPollMs = $ackPollMs
                hostStartedUtc = $hostStartedUtc.ToString('o')
                hostQueuedUtc = $hostQueuedUtc.ToString('o')
                hostAcknowledgedUtc = [DateTime]::UtcNow.ToString('o')
                hostElapsedMs = $timer.ElapsedMilliseconds
            }
            if ($ShelldiverTimingSamples -is [Collections.Generic.List[object]]) {
                $ShelldiverTimingSamples.Add([pscustomobject]@{
                    action=$Action; queueToAckMs=$result.hostQueueToAckMs
                    totalMs=$result.hostElapsedMs; frame=$result.frame; pollMs=$ackPollMs
                })
            }
            return $result
        }
        Start-Sleep -Milliseconds $ackPollMs
    }
    throw "Shelldiver did not acknowledge '$Action' in $TimeoutSeconds seconds. Command $requestId may still execute."
} finally {
    try {
        [IO.File]::Delete($temporaryPath)
    } finally {
        if ($lease) { $lease.Dispose() }
    }
}
