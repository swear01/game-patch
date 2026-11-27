[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Move', 'Interact', 'SellCollect')]
    [string]$Action,

    [ValidateRange(0.0, 6400.0)]
    [double]$X,

    [ValidateRange(4.0, 48.0)]
    [double]$Tolerance = 12,

    [ValidateRange(1, 600)]
    [int]$Frames = 1,

    [switch]$HoldOnly,

    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),

    [ValidateRange(3, 120)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$timer = [Diagnostics.Stopwatch]::StartNew()

function Get-RemainingSeconds {
    return [Math]::Max(1, [Math]::Min(5, [Math]::Ceiling($TimeoutSeconds - $timer.Elapsed.TotalSeconds)))
}

function Read-IslandSnapshot {
    $state = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds (Get-RemainingSeconds)
    if ($state.room -ne 'rm_main_island') {
        throw "This route runs on rm_main_island. Current room is '$($state.room)'."
    }
    if ($gamePid -and $state.pid -ne $gamePid) {
        throw 'Shelldiver restarted while the route was active.'
    }
    if ($state.inputError -and $state.inputError -ne 'Could not publish the game mailbox response.') {
        throw "Shelldiver input failed. $($state.inputError)"
    }
    return $state
}

function Wait-IslandSnapshot([scriptblock]$Condition, [string]$Expected) {
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $state = Read-IslandSnapshot
        if (& $Condition $state) { return $state }
        Start-Sleep -Milliseconds 25
    }
    throw "Timed out waiting for $Expected."
}

function Invoke-IslandInput([int]$Count, [hashtable]$Values) {
    if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'The island route has timed out.' }
    $parameters = @{ frames = $Count; values = $Values } | ConvertTo-Json -Depth 3 -Compress
    $reply = & $control -Action input -ParametersJson $parameters -Mailbox $Mailbox -TimeoutSeconds (Get-RemainingSeconds)
    if ($null -eq $reply.frame) { throw 'The native input acknowledgement did not include a frame.' }
    $lastInputFrame = [long]$reply.frame + $Count - 1
    return Wait-IslandSnapshot {
        param($state)
        $observedPlayerFrame = $state.scene.player.frame
        $state.frame -gt $lastInputFrame -and $state.activeInputFrames -eq 0 -and
            $null -ne $state.scene.player.x -and
            ($null -eq $observedPlayerFrame -or $observedPlayerFrame -gt $lastInputFrame)
    } "the position after input frame $lastInputFrame"
}

function Move-Island([double]$Target, $State) {
    $pixelsPerFrame = 3.0
    $stalledPulses = 0
    while ([Math]::Abs($Target - $State.scene.player.x) -gt $Tolerance) {
        $from = [double]$State.scene.player.x
        $delta = $Target - $from
        $count = [int][Math]::Clamp([Math]::Floor(([Math]::Abs($delta) - $Tolerance / 2) / $pixelsPerFrame), 1, 90)
        $State = Invoke-IslandInput $count @{
            left = ($delta -lt 0)
            right = ($delta -gt 0)
            is_moving_any = $true
            is_moving_horizontal = $true
        }

        $travel = ($State.scene.player.x - $from) * [Math]::Sign($delta)
        if ($travel -lt 0.25) {
            ++$stalledPulses
            if ($stalledPulses -ge 3) { throw "Player did not move toward x=$Target after three native input pulses." }
        } else {
            $stalledPulses = 0
            $pixelsPerFrame = [Math]::Clamp($travel / $count, 0.5, 20.0)
        }
    }
    return $State
}

function Invoke-IslandInteract([int]$Count) {
    $pressed = if ($HoldOnly) { 0 } else { 1 }
    return Invoke-IslandInput $Count @{ interact = $pressed; interact_hold = ($HoldOnly -or $Count -gt 1) }
}

if ($Action -eq 'Move' -and !$PSBoundParameters.ContainsKey('X')) { throw 'Move requires -X.' }
$gamePid = $null
$initial = Read-IslandSnapshot
$gamePid = $initial.pid
if (!$gamePid) { throw 'The Shelldiver snapshot is missing its process ID.' }
$state = Wait-IslandSnapshot {
    param($sample)
    $sample.frame -gt $initial.frame -and $sample.inputReady -and $sample.activeInputFrames -eq 0 -and
        $null -ne $sample.scene.player.x
} 'live island player telemetry and idle native input'

switch ($Action) {
    'Move' { return Move-Island $X $state }
    'Interact' { return Invoke-IslandInteract $Frames }
    'SellCollect' {
        $state = Wait-IslandSnapshot {
            param($sample)
            $null -ne $sample.scene.shop.x -and $null -ne $sample.scene.chest.x -and
                $null -ne $sample.numbers.store_shell_coins -and $null -ne $sample.numbers.shell_coins
        } 'the native shop, chest, and shell balances'
        $storeBefore = $state.numbers.store_shell_coins
        $state = Move-Island $state.scene.shop.x $state
        $state = Invoke-IslandInteract 90
        $state = Wait-IslandSnapshot {
            param($sample)
            $sample.numbers.store_shell_coins -gt $storeBefore
        } 'the store to receive shell coins from a sale'

        $shellsBefore = $state.numbers.shell_coins
        $state = Move-Island $state.scene.chest.x $state
        $state = Invoke-IslandInteract 90
        return Wait-IslandSnapshot {
            param($sample)
            $sample.numbers.shell_coins -gt $shellsBefore
        } 'the native chest to add shell coins to the player balance'
    }
}
