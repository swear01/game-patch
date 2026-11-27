[CmdletBinding()]
param(
    [ValidateSet('Dive', 'Return', 'Move', 'Target')]
    [string]$Action = 'Dive',

    [ValidateRange(0.0, 1760.0)]
    [double]$X,

    [ValidateRange(0.0, 1600.0)]
    [double]$Y,

    [ValidateSet('Jellyfish', 'Resource', 'Mixed')]
    [string]$Kind = 'Jellyfish',

    [ValidateRange(1, 30)]
    [int]$HoldFrames = 16,

    [ValidateRange(46, 200)]
    [int]$PlasmaHoldFrames = 200,

    [ValidateRange(62, 264)]
    [int]$MagmaPlasmaAimRange = 108,

    [ValidateRange(13, 140)]
    [int]$MagmaPlasmaChargeFrames = 35,

    [ValidateSet('West', 'East')]
    [string]$MagmaMineSector = 'West',

    [switch]$MagmaShockFrequency,

    [switch]$MagmaShockResistance,

    [switch]$MagmaShockResistanceII,

    [long]$MagmaBeforeEntryFrame,

    [switch]$RecoverMagma,

    [ValidateRange(0, 45)] [int]$ReturnApproachDistance,

    [ValidateRange(0.0, 1.0)]
    [double]$ConfirmX = 0.4375,

    [ValidateRange(0.0, 1.0)]
    [double]$ConfirmY = (196.0 / 360),

    [ValidateRange(35, 95)]
    [int]$ReturnOxygen = 65,

    [ValidateRange(1, 35)]
    [int]$HarvestSeconds = 6,

    [ValidateRange(8, 90)]
    [int]$TimeoutSeconds = 20,

    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),

    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json'),

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$BeforeDiveSaveHash,

    [switch]$ResultVerified,

    [switch]$UseSubmarineBubble,

    [switch]$UseSubmarineAmmoBubble,

    [ValidateRange(1.0, 12.0)] [double]$MagmaBubblePenetration = 1.0,

    [ValidateRange(4.0, 25.0)] [double]$MagmaBubbleProjectileSpeed = 4.0,

    [ValidateRange(30, 120)] [int]$MagmaBubbleProjectileLifetime = 30,

    [switch]$RequireLiveDiver,

    [switch]$FillBackpack,
    [switch]$HoldResult
)

$ErrorActionPreference = 'Stop'
$magmaContactDrop = if ($MagmaShockResistance) { 7000 } else { 12000 }
$diveDeadline = if ($FillBackpack) { [double]::PositiveInfinity } else { [double]$TimeoutSeconds }
$mixed = $Kind -eq 'Mixed'
if ($mixed -and $Action -ne 'Dive') { throw 'Mixed harvesting requires -Action Dive.' }
. (Join-Path $PSScriptRoot 'ShelldiverMailbox.ps1')
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$diveRooms = @{}
$regions = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'ShelldiverRegions.psd1')
foreach ($region in $regions.Values) { $diveRooms[$region.room] = $region }
$diveRoom = $null
$nativeTerrain = $null
$terrainPath = Join-Path $PSScriptRoot 'ShelldiverTerrain.original.json'
if ([IO.File]::Exists($terrainPath)) {
    $terrain = [IO.File]::ReadAllText($terrainPath) | ConvertFrom-Json -AsHashtable
    if ($terrain.schemaVersion -eq 1 -and
        $terrain.sourceSha256 -eq '4b4f08b6c85fd3852a08bccdbb0d6621cc614225f9f804df6afe79258e8c0506') {
        $nativeTerrain = $terrain.rooms
        foreach ($map in $nativeTerrain.Values) { $map.rows = [string[]]$map.rows }
        if (!('ShelldiverTerrainSegment' -as [type])) {
            Add-Type -TypeDefinition @"
using System;

public static class ShelldiverTerrainSegment
{
    public static bool IsClear(string[] rows, int tileWidth, int tileHeight,
        double startX, double startY, double endX, double endY, double margin)
    {
        double dx = endX - startX;
        double dy = endY - startY;
        int samples = (int)Math.Max(1, Math.Ceiling(Math.Sqrt(dx * dx + dy * dy) / 5));
        for (int sample = 0; sample <= samples; ++sample)
        {
            double fraction = (double)sample / samples;
            double px = startX + dx * fraction;
            double py = startY + dy * fraction;
            int minX = (int)Math.Floor((px - margin) / tileWidth);
            int maxX = (int)Math.Floor((px + margin) / tileWidth);
            int minY = (int)Math.Floor((py - margin) / tileHeight);
            int maxY = (int)Math.Floor((py + margin) / tileHeight);
            if (minX < 0 || minY < 0 || maxY >= rows.Length || maxX >= rows[0].Length)
                return false;
            for (int y = minY; y <= maxY; ++y)
                for (int x = minX; x <= maxX; ++x)
                    if (rows[y][x] == '#')
                        return false;
        }
        return true;
    }
}
"@
        }
    }
}
$timer = [Diagnostics.Stopwatch]::StartNew()
$gamePid = $null
$returnCheckpoint = Join-Path $Mailbox 'dive-return.json'

function Get-CommandTimeout {
    $remaining = [Math]::Ceiling($diveDeadline - $timer.Elapsed.TotalSeconds)
    return [int][Math]::Clamp($remaining, 1.0, 3.0)
}

function Update-DiveFullObservation($Sample) {
    if ($Action -ne 'Dive' -or !$script:diveEntryFrame -or $script:diveFull -or $script:diveDocking -or
        $Sample.pid -ne $gamePid -or $Sample.room -ne $diveRoom -or $Sample.flags.transitioning) { return }
    $fullFrame = [long]$Sample.frame
    $source = $null
    $bag = $Sample.inventories.player
    if ($Sample.scene.player.is_inventory_full -eq 1 -or $Sample.scene.player.inventory_full -eq 1) {
        $source = 'native-player'
    } elseif ($bag.slotCount -gt 0 -and $bag.slotCapacity -gt 0 -and $bag.total -ge $bag.slotCount*$bag.slotCapacity) {
        $source = 'native-slot-capacity'
    } elseif ($timer.ElapsedMilliseconds -ge $script:nextFullBadgeMs) {
        $script:nextFullBadgeMs = $timer.ElapsedMilliseconds + 100
        try { $badge = [IO.File]::ReadAllText((Join-Path $Mailbox 'catch-badge.json')) | ConvertFrom-Json } catch { return }
        $at = if ($badge.firstFullFrame -gt $script:diveEntryFrame) { $badge.firstFullFrame } else { $badge.lastFullFrame }
        if ($badge.pid -ne $gamePid -or $badge.room -ne $diveRoom -or $at -le $script:diveEntryFrame -or
            $at -gt $Sample.frame -or $badge.observedFrame -lt $at) { return }
        $source = if ($badge.firstFullSource) { [string]$badge.firstFullSource } else { 'full-badge' }
        $fullFrame = [long]$at
    }
    if ($source) {
        $script:diveFull = [ordered]@{source=$source;fullFrame=$fullFrame;firstReadFrame=$Sample.frame;returnRequestedFrame=$null}
    }
}

function Read-DiveSnapshot {
    $state = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds (Get-CommandTimeout)
    if ($state.flags.pause -and $state.room -eq 'rm_ocean_magma_03') {
        # A brief native pause may clear while the same diver is still in the ocean.
        # Observe the game without pressing Resume or sending steering input.
        $pausedPid = $state.pid
        $pauseWatch = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 40
            $state = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds (Get-CommandTimeout)
        } while ($state.flags.pause -and $state.pid -eq $pausedPid -and
            $state.room -eq 'rm_ocean_magma_03' -and $pauseWatch.Elapsed.TotalSeconds -lt 2)
    }
    if ($gamePid -and $state.pid -ne $gamePid) { throw 'Shelldiver restarted during the dive.' }
    $allowedRooms = if ($diveRoom) { $diveRoom, 'rm_main_island' } else { $diveRooms.Keys }
    if ($state.room -notin $allowedRooms) { throw "Unexpected Shelldiver room '$($state.room)'." }
    if ($state.inputError -and $state.inputError -ne 'Could not publish the game mailbox response.') {
        throw "Shelldiver input failed. $($state.inputError)"
    }
    Update-DiveFullObservation $state
    return $state
}

function Wait-DiveSnapshot([scriptblock]$Condition, [string]$Expected, [switch]$AllowIsland, [switch]$AllowEmptyOxygen, [double]$MaxWaitSeconds) {
    $deadline = if ($FillBackpack) { $timer.Elapsed.TotalSeconds+8 } else { $diveDeadline }
    if ($MaxWaitSeconds -gt 0) {
        $deadline = [Math]::Min($deadline, $timer.Elapsed.TotalSeconds + $MaxWaitSeconds)
    }
    while ($timer.Elapsed.TotalSeconds -lt $deadline) {
        $sample = Read-DiveSnapshot
        if ($sample.room -eq 'rm_main_island') {
            if ($AllowIsland) { return $sample }
            throw 'Shelldiver left the dive before the requested action finished.'
        }
        if (!$AllowEmptyOxygen -and $null -ne $sample.scene.player.oxygen -and $sample.scene.player.oxygen -le 0) {
            throw 'The expedition has run out of oxygen.'
        }
        if (& $Condition $sample) { return $sample }
        Start-Sleep -Milliseconds 20
    }
    throw "Timed out waiting for $Expected."
}

function Invoke-DiveCommand($State, [string]$Command, [hashtable]$Parameters, [int]$Frames, [switch]$AllowIsland, [switch]$ResultStage,
                            [double]$MaxWaitSeconds, [int]$AckTimeout, [switch]$AcknowledgeOnly,
                            [long]$NativePointerExpiryFrame, [switch]$TrackAcknowledgement) {
    if ($timer.Elapsed.TotalSeconds -ge $diveDeadline) { throw 'The dive has timed out.' }
    if ($State.room -ne $diveRoom -or (!$ResultStage -and $State.scene.player.oxygen -le 0)) {
        throw 'Shelldiver is outside the expected dive stage.'
    }
    $json = ConvertTo-Json -InputObject $Parameters -Depth 3 -Compress
    $commandTimeout = if ($AckTimeout -gt 0) { $AckTimeout } else { Get-CommandTimeout }
    $ack = & $control -Action $Command -ParametersJson $json -Mailbox $Mailbox -TimeoutSeconds $commandTimeout
    if ($null -eq $ack.frame) { throw "The native '$Command' acknowledgement was missing a frame." }
    if ($AcknowledgeOnly) { return $ack }
    $lastInputFrame = [long]$ack.frame + $Frames - 1
    $lastActionFrame = [Math]::Max($lastInputFrame,$NativePointerExpiryFrame)
    $observed = Wait-DiveSnapshot {
        param($sample)
        $sample.frame -gt $lastActionFrame -and $sample.activeInputFrames -eq 0 -and
            (!$NativePointerExpiryFrame -or !$sample.guiPointer.active) -and
            $null -ne $sample.scene.player.x -and $null -ne $sample.scene.player.y -and
            $null -ne $sample.scene.player.oxygen -and
            ($null -eq $sample.scene.player.frame -or $sample.scene.player.frame -gt $lastActionFrame)
    } "fresh telemetry after '$Command' frame $lastActionFrame" -AllowIsland:$AllowIsland -AllowEmptyOxygen:$ResultStage `
        -MaxWaitSeconds $MaxWaitSeconds
    if ($TrackAcknowledgement) { $observed | Add-Member -NotePropertyName diveCommandAckFrame -NotePropertyValue ([long]$ack.frame) -Force }
    return $observed
}

function Get-Distance($First, $Second) {
    $dx = $Second.x - $First.x
    $dy = $Second.y - $First.y
    return [Math]::Sqrt($dx * $dx + $dy * $dy)
}

function Test-OceanSegment($Room, $From, $To, [int]$Margin = 0) {
    $map = if ($nativeTerrain) { $nativeTerrain[$Room] }
    if (!$map) { return $true }
    return [ShelldiverTerrainSegment]::IsClear(
        $map.rows, $map.tileWidth, $map.tileHeight, $From.x, $From.y, $To.x, $To.y, $Margin)
}

function Get-StandOffPoint($Player, $Target, [double]$Distance, [double]$PreferredDistance = 66) {
    if ($Distance -le 1) { return }
    return @{
        x=$Target.x + $PreferredDistance * ($Player.x - $Target.x) / $Distance
        y=$Target.y + $PreferredDistance * ($Player.y - $Target.y) / $Distance
    }
}

function Test-FishAccess($State, $Target) {
    $player = $State.scene.player
    if (!(Test-OceanSegment $State.room $player $Target)) { return $false }
    $distance = Get-Distance $player $Target
    if ($distance -ge 48 -and $distance -le 82) { return $true }
    $point = Get-StandOffPoint $player $Target $distance
    return $point -and (Test-OceanSegment $State.room $player $point 10)
}

function Test-SwampOreAccess($State, $Target) {
    $player = $State.scene.player
    if (!(Test-OceanSegment $State.room $player $Target)) { return $false }
    $distance = Get-Distance $player $Target
    if ($distance -le 62) { return $true }
    $point = Get-StandOffPoint $player $Target $distance 54
    return $point -and (Test-OceanSegment $State.room $player $point 12)
}

function Get-LiveSubmarine($State) {
    $anchor = $State.scene.submarineLeave
    if ($null -eq $anchor.x -or $null -eq $anchor.y -or $null -eq $anchor.frame -or
        $anchor.frame -gt $State.frame -or $State.frame - $anchor.frame -gt 45) {
        throw 'The current bridge does not have live submarine position telemetry.'
    }
    return $anchor
}

function Get-OxygenPercent($State) {
    $maximum = $State.scene.player.oxygen_max
    if ($maximum -gt 0) { return (100 * $State.scene.player.oxygen / $maximum) }
    return $State.scene.player.oxygen
}

function Get-SwimPulsePlan($State, $Target, [int]$FrameLimit, [double]$PixelsPerFrame, [switch]$TrackFrames, [switch]$AnalogHeading) {
    $dx = $Target.x - $State.scene.player.x
    $dy = $Target.y - $State.scene.player.y
    $major = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dy))
    $axisThreshold = [Math]::Max(3.0, $major * 0.32)
    $minimumFrames = if ($TrackFrames) { 6 } else { 1 }
    $count = [int][Math]::Clamp([Math]::Floor(($major - 6) / $PixelsPerFrame), $minimumFrames, $FrameLimit)
    $values = @{
        left = ($dx -lt -$axisThreshold)
        right = ($dx -gt $axisThreshold)
        up = ($dy -lt -$axisThreshold)
        down = ($dy -gt $axisThreshold)
        is_moving_any = $true
        is_moving_horizontal = ([Math]::Abs($dx) -gt $axisThreshold)
    }
    $analog=$AnalogHeading -and $major -gt 1
    $vx=0.0; $vy=0.0
    $wantedX=0.0; $wantedY=0.0
    if ($analog) {
        $prior=$script:magmaLastAnalogPosition
        $elapsed=if ($prior -and $prior.pid -eq $State.pid -and $prior.room -eq $State.room) {
            $State.scene.player.frame-$prior.scene.player.frame
        } else { 0 }
        if ($elapsed -ge 6 -and $elapsed -le 85) {
            $vx=[Math]::Clamp(($State.scene.player.x-$prior.scene.player.x)/$elapsed,-3.4,3.4)
            $vy=[Math]::Clamp(($State.scene.player.y-$prior.scene.player.y)/$elapsed,-3.4,3.4)
        }
        # An independent stick value on each axis can steer the game’s original movement lerp.
        $carry=.97*(1-[Math]::Pow(.97,$count))/.03
        $response=[Math]::Max(1.0,$count-$carry)
        $wantedX=[Math]::Clamp(($dx-.72*$vx*$carry)/(3.3*$response),-1.0,1.0)
        $wantedY=[Math]::Clamp(($dy-.72*$vy*$carry)/(3.3*$response),-1.0,1.0)
        $values.left=[Math]::Max(0.0,-$wantedX)
        $values.right=[Math]::Max(0.0,$wantedX)
        $values.up=[Math]::Max(0.0,-$wantedY)
        $values.down=[Math]::Max(0.0,$wantedY)
        $values.is_moving_horizontal=[Math]::Abs($wantedX) -gt .08
    }
    return @{frames=$count;values=$values;analog=$analog;vx=$vx;vy=$vy;wantedX=$wantedX;wantedY=$wantedY}
}

function Swim-Pulse($State, $Target, [int]$FrameLimit, [double]$PixelsPerFrame, [switch]$Returning, [switch]$Adaptive,
                    [switch]$TrackFrames, [switch]$CloseInventory, [switch]$AnalogHeading,
                    $PreparedPulse, [long]$NativePointerExpiryFrame, [switch]$TrackAcknowledgement) {
    if ($Adaptive) { $PixelsPerFrame = $script:harvestPulseSpeed }
    $plan = if ($PreparedPulse) { $PreparedPulse }
        else { Get-SwimPulsePlan $State $Target $FrameLimit $PixelsPerFrame -TrackFrames:$TrackFrames -AnalogHeading:$AnalogHeading }
    if ($plan.analog) { $script:magmaLastAnalogPosition=$State }
    $count=$plan.frames
    $values=$plan.values
    if ($CloseInventory) { $values.open_inventory = $true }
    $observed = Invoke-DiveCommand $State input @{frames = $count; values = $values} $count `
        -AllowIsland:$Returning -ResultStage:$Returning -NativePointerExpiryFrame:$NativePointerExpiryFrame -TrackAcknowledgement:$TrackAcknowledgement
    if ($Adaptive -and $count -ge 4 -and $observed.room -eq $State.room -and $observed.scene.player.can_use_tool -eq 1) {
        $measured = [Math]::Max([Math]::Abs($observed.scene.player.x - $State.scene.player.x),
            [Math]::Abs($observed.scene.player.y - $State.scene.player.y)) / $count
        if ($measured -ge 1) {
            $script:harvestPulseSpeed = [Math]::Clamp(.4 * $PixelsPerFrame + .6 * $measured, 2.0, 12.0)
        }
    }
    if ($TrackFrames) { $observed | Add-Member -NotePropertyName swimPulseFrames -NotePropertyValue $count -Force }
    return $observed
}

function Swim-To($State, $Target, [double]$Tolerance, [switch]$Returning, [switch]$Backtrack) {
    $estimatedSpeed = 2.5
    $inReturn = $Returning -or $Backtrack
    $frameLimit = if ($Backtrack) { 24 } else { 48 }
    $stalledPulses = 0
    $distance = Get-Distance $State.scene.player $Target
    while ($distance -gt $Tolerance) {
        if ($State.scene.player.can_use_tool -eq 0) {
            if ($inReturn) { return $State }
            throw 'The game has suspended dive movement for a native UI or cutscene.'
        }
        if (!$inReturn -and (Get-OxygenPercent $State) -le $ReturnOxygen) {
            throw "Stopped moving away from the submarine at the oxygen reserve."
        }
        $from = $State.scene.player
        $motionTarget = $Target
        $State = Swim-Pulse $State $motionTarget $frameLimit $estimatedSpeed -Returning:$inReturn
        if ($inReturn -and ($State.room -eq 'rm_main_island' -or
            $State.scene.player.can_use_tool -eq 0 -or $State.scene.player.oxygen -le 0)) { return $State }
        if ($Returning) { $Target = Get-LiveSubmarine $State }
        $nextDistance = Get-Distance $State.scene.player $Target
        if ($distance - $nextDistance -lt 0.5) {
            ++$stalledPulses
            if ($stalledPulses -ge 3) { throw "Could not swim toward ($($Target.x), $($Target.y)) after three pulses." }
        } else {
            $stalledPulses = 0
            $major = [Math]::Max([Math]::Abs($motionTarget.x - $from.x), [Math]::Abs($motionTarget.y - $from.y))
            $previousFrames = [Math]::Clamp([Math]::Floor(($major - 6) / $estimatedSpeed), 1, $frameLimit)
            $estimatedSpeed = [Math]::Clamp((Get-Distance $from $State.scene.player) / $previousFrames, 0.5, 20.0)
        }
        $distance = $nextDistance
    }
    return $State
}

function Get-MagmaPressureReserve([double]$SwimDistance, [double]$FramesPerPixel, [int]$ActionFrames = 0) {
    # The final 55px to the interaction anchor lie within the verified pressure shelter.
    $exposedDistance = [Math]::Max(0, $SwimDistance - 55)
    $travelFrames = [Math]::Ceiling($exposedDistance * $FramesPerPixel) + 54
    $shotFrames = if ($ActionFrames -gt 0) { $ActionFrames + 30 } else { 0 }
    # Magma I uses 4,000 oxygen per 30 frames. Include emergency headroom for late telemetry or knockback.
    return 4000 * ([Math]::Ceiling(($travelFrames + $shotFrames) / 30) + 2) + 20000
}

function Test-MagmaSwimClear($State, $From, $To, [double]$Margin = 112) {
    $dx = $To.x - $From.x
    $dy = $To.y - $From.y
    $lengthSquared = $dx * $dx + $dy * $dy
    foreach ($jellyfish in $State.targets.jellyfish) {
        if ($null -eq $jellyfish.x -or $null -eq $jellyfish.y) { continue }
        $fromFishX = $jellyfish.x - $From.x
        $fromFishY = $jellyfish.y - $From.y
        $alongRoute = if ($lengthSquared -gt 0) {
            [Math]::Clamp(($fromFishX * $dx + $fromFishY * $dy) / $lengthSquared, 0.0, 1.0)
        } else { 0 }
        $nearest = @{x=($From.x + $dx * $alongRoute);y=($From.y + $dy * $alongRoute)}
        if ((Get-Distance $nearest $jellyfish) -ge $Margin) { continue }
        if ($alongRoute -gt 0 -or (Get-Distance $To $jellyfish) -le (Get-Distance $From $jellyfish) + 12) {
            return $false
        }
    }
    return $true
}

function Get-MagmaNearestFishDistance($State, $Position) {
    $closest = [double]::PositiveInfinity
    foreach ($target in $State.targets.jellyfish) {
        if ($null -ne $target.x -and $null -ne $target.y) {
            $closest = [Math]::Min($closest, (Get-Distance $Position $target))
        }
    }
    return $closest
}

function Get-MagmaPath($State, $From, $To, $Pivots, [double]$TerrainMargin = 18, [switch]$TerrainOnly) {
    if ((Test-OceanSegment $State.room $From $To $TerrainMargin) -and
        ($TerrainOnly -or (Test-MagmaSwimClear $State $From $To))) {
        return @{ point=$To; distance=(Get-Distance $From $To) }
    }
    $nearestPath = $null
    foreach ($pivot in $Pivots) {
        $outbound = Get-Distance $From $pivot
        if ($outbound -le 13 -or !(Test-OceanSegment $State.room $From $pivot $TerrainMargin) -or
            !(Test-OceanSegment $State.room $pivot $To $TerrainMargin) -or
            (!$TerrainOnly -and (!(Test-MagmaSwimClear $State $From $pivot) -or
                !(Test-MagmaSwimClear $State $pivot $To)))) { continue }
        $distance = $outbound + (Get-Distance $pivot $To)
        if (!$nearestPath -or $distance -lt $nearestPath.distance) {
            $nearestPath = @{point=$pivot; distance=$distance}
        }
    }
    if (!$nearestPath -and $script:magmaMiningEast) {
        $upperShaft = @{x=378;y=112}
        $middleShaft = @{x=508;y=256}
        $crossings = @(
            @{first=$upperShaft;second=$middleShaft}
            @{first=$middleShaft;second=$upperShaft}
        )
        foreach ($crossing in $crossings) {
            $first = $crossing.first
            $second = $crossing.second
            $steps = @(@{from=$From;to=$first},@{from=$first;to=$second},@{from=$second;to=$To})
            $blocked = $steps | Where-Object {
                !(Test-OceanSegment $State.room $_.from $_.to $TerrainMargin) -or
                (!$TerrainOnly -and !(Test-MagmaSwimClear $State $_.from $_.to))
            } | Select-Object -First 1
            if ($blocked -or (Get-Distance $From $first) -le 13) { continue }
            $distance = (Get-Distance $From $first) + (Get-Distance $first $second) + (Get-Distance $second $To)
            if (!$nearestPath -or $distance -lt $nearestPath.distance) {
                $nearestPath = @{point=$first;distance=$distance}
            }
        }
    }
    return $nearestPath
}

function Get-MagmaScoutPlan($State, $From, $Target, $Pivots, [double]$TerrainMargin) {
    $plan = Get-MagmaPath $State $From $Target $Pivots $TerrainMargin -TerrainOnly
    if (!$plan) { return $null }
    $distance = Get-Distance $From $plan.point
    if ($distance -le 0) { return $null }
    $clearance = Get-MagmaNearestFishDistance $State $From
    $frames = if ($clearance -lt 225) { 8 } else { 20 }
    $simulatedDistance = [Math]::Min($distance, $frames * 4.5 + 12)
    $forecast = @{
        x=$From.x + ($plan.point.x - $From.x) * $simulatedDistance / $distance
        y=$From.y + ($plan.point.y - $From.y) * $simulatedDistance / $distance
    }
    if (!(Test-MagmaSwimClear $State $From $forecast)) {
        if ($frames -eq 8) { return $null }
        $frames = 8
        $shorter = [Math]::Min(1.0, 48.0 / $distance)
        $forecast.x = $From.x + ($plan.point.x - $From.x) * $shorter
        $forecast.y = $From.y + ($plan.point.y - $From.y) * $shorter
        if (!(Test-MagmaSwimClear $State $From $forecast)) { return $null }
    }
    $plan.frames = $frames
    return $plan
}

function Get-MagmaPickupPlan($State, $Ore, $Anchor, $Pivots, [double]$FramesPerPixel) {
    $player = $State.scene.player
    $distance = Get-Distance $player $Ore
    if ($distance -le 26) { return $null }
    $radial = @{
        x=$Ore.x + 24 * ($player.x - $Ore.x) / $distance
        y=$Ore.y + 24 * ($player.y - $Ore.y) / $distance
    }
    $candidates = $radial,
        @{x=$Ore.x-22;y=$Ore.y-3}, @{x=$Ore.x+23;y=$Ore.y},
        @{x=$Ore.x;y=$Ore.y-24}, @{x=$Ore.x;y=$Ore.y+24},
        @{x=$Ore.x-18;y=$Ore.y-18}, @{x=$Ore.x+18;y=$Ore.y-18}
    $best = $null
    foreach ($point in $candidates) {
        $out = Get-MagmaPath $State $player $point $Pivots
        if (!$out) { continue }
        $exit = Get-MagmaPath $State $point $Anchor $Pivots
        if (!$exit) { continue }
        $total = $out.distance + $exit.distance
        if ($player.oxygen -le (Get-MagmaPressureReserve $total $FramesPerPixel)) { continue }
        if (!$best -or $total -lt $best.distance) {
            $best = @{point=$out.point; destination=$point; distance=$total}
        }
    }
    return $best
}

function Add-MagmaReturnObservation($State, $Previous) {
    if ($State.room -ne $diveRoom -or $null -eq $State.scene.player.oxygen) { return }
    $oxygen = [double]$State.scene.player.oxygen
    if ($null -eq $script:magmaMinimumReturnOxygen -or $oxygen -lt $script:magmaMinimumReturnOxygen) {
        $script:magmaMinimumReturnOxygen = $oxygen
    }
    $clearance = Get-MagmaNearestFishDistance $State $State.scene.player
    $script:magmaMinFishClearance = [Math]::Min($script:magmaMinFishClearance, $clearance)
    if ($Previous -and $Previous.scene.player.can_use_tool -ne 0 -and
        $State.scene.player.can_use_tool -eq 0 -and $Previous.scene.player.oxygen - $oxygen -ge $magmaContactDrop) {
        ++$script:magmaPossibleContacts
    }
}
function Get-MagmaRetreatStep($State, $Anchor, $Trail, [double]$TerrainMargin) {
    $from = $State.scene.player
    $toShelter = Get-Distance $from $Anchor
    $nearestNow = Get-MagmaNearestFishDistance $State $from
    $best = $null
    $bestScore = [double]::NegativeInfinity
    $points = @($Trail)
    foreach ($direction in 0..7) {
        $angle = $direction * [Math]::PI / 4
        foreach ($distance in 20,34) {
            $points += @{x=$from.x + $distance * [Math]::Cos($angle);y=$from.y + $distance * [Math]::Sin($angle)}
        }
    }
    foreach ($margin in 112,100) {
        foreach ($candidate in $points) {
            $stepLength = Get-Distance $from $candidate
            if ($stepLength -lt 15 -or $stepLength -gt 65 -or
                !(Test-OceanSegment $State.room $from $candidate $TerrainMargin) -or
                !(Test-MagmaSwimClear $State $from $candidate $margin)) { continue }
            $gain = $toShelter - (Get-Distance $candidate $Anchor)
            $clearance = Get-MagmaNearestFishDistance $State $candidate
            $separation = if ([double]::IsInfinity($nearestNow)) { 0 } else {
                [Math]::Min(65, $clearance - $nearestNow)
            }
            if ($gain -lt 2 -and ($nearestNow -ge 112 -or $separation -lt 10)) { continue }
            $score = $gain + $(if ($nearestNow -lt 112) { $separation } else { .12 * $separation })
            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = @{point=$candidate; distance=$stepLength}
            }
        }
        if ($best) { return $best }
    }
    return $null
}

function Test-MagmaRetreatPulseFishClear($State, $From, $To, [double]$Clearance) {
    $dx = [double]($To.x - $From.x)
    $dy = [double]($To.y - $From.y)
    $lengthSquared = $dx * $dx + $dy * $dy
    if ($lengthSquared -le 0) { return $false }
    foreach ($fish in $State.targets.jellyfish) {
        if ($null -eq $fish.x -or $null -eq $fish.y) { continue }
        $fx = [double]($fish.x - $From.x)
        $fy = [double]($fish.y - $From.y)
        $along = [Math]::Clamp((($fx * $dx + $fy * $dy) / $lengthSquared), 0.0, 1.0)
        $nearest = @{ x=($From.x + $dx * $along); y=($From.y + $dy * $along) }
        $start = Get-Distance $From $fish
        if ((Get-Distance $nearest $fish) -lt [Math]::Min($Clearance, $start) - 0.01) { return $false }
        if ($start -lt $Clearance -and (Get-Distance $To $fish) -lt $start + 4) { return $false }
    }
    return $true
}

function Get-MagmaLocalEscape($State, $Anchor, $Pivots, [double]$TerrainMargin) {
    $from = $State.scene.player
    $nearest = Get-MagmaNearestFishDistance $State $from
    if ($nearest -ge 112) { return $null }
    $returnPlan = Get-MagmaPath $State $from $Anchor $Pivots $TerrainMargin -TerrainOnly
    $distance = if ($returnPlan) { $returnPlan.distance } else { Get-Distance $from $Anchor }
    $best = $null
    $bestScore = [double]::NegativeInfinity
    $directions = @{x=1;y=0}, @{x=1;y=1}, @{x=0;y=1}, @{x=-1;y=1},
        @{x=-1;y=0}, @{x=-1;y=-1}, @{x=0;y=-1}, @{x=1;y=-1}
    foreach ($heading in $directions) {
        foreach ($stride in 24,16,10) {
            $point = @{x=$from.x + $heading.x * $stride;y=$from.y + $heading.y * $stride}
            $forecast = @{x=$from.x + $heading.x * ($stride+10);y=$from.y + $heading.y * ($stride+10)}
            if (!(Test-OceanSegment $State.room $from $forecast $TerrainMargin) -or
                !(Test-MagmaRetreatPulseFishClear $State $from $forecast 60.0)) { continue }
            $exit = Get-MagmaPath $State $point $Anchor $Pivots $TerrainMargin -TerrainOnly
            $nextExit = if ($exit) { Get-MagmaPath $State $forecast $Anchor $Pivots $TerrainMargin -TerrainOnly }
            if (!$exit -or !$nextExit) { continue }
            $gain = $distance - $exit.distance
            $separation = (Get-MagmaNearestFishDistance $State $point) - $nearest
            if ($gain -lt 1 -and $separation -lt 6) { continue }
            $score = $gain + 2.0 * $separation
            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = @{point=$point;distance=$exit.distance;emergency=$true}
            }
        }
    }
    return $best
}
function Swim-MagmaSafeReturn($State, [double]$TargetDistance, $Trail) {
    $stalls = 0
    while ($State.room -eq $diveRoom -and $State.scene.player.can_use_tool -eq 1 -and $State.scene.player.oxygen -gt 0) {
        $anchor = Get-LiveSubmarine $State
        $position = $State.scene.player
        Add-MagmaReturnObservation $State $null
        $distance = Get-Distance $position $anchor
        if ($distance -le $TargetDistance) { return $State }

        # The stock interaction can be reached from the near edge of its radius.
        $approach = @{
            x=$anchor.x + ($position.x - $anchor.x) * ($TargetDistance - 8) / $distance
            y=$anchor.y + ($position.y - $anchor.y) * ($TargetDistance - 8) / $distance
        }
        $margin = if (Test-OceanSegment $State.room $position $position 8) { 8 } else { 4 }
        $plan = if ($stalls -lt 2) { Get-MagmaPath $State $position $approach $Trail $margin }
        if (!$plan) {
            $plan = Get-MagmaRetreatStep $State $approach $Trail $margin
            if (!$plan) { $plan = Get-MagmaLocalEscape $State $approach $Trail $margin }
            if ($plan) { ++$script:magmaPartialRetreats }
        }
        if ($plan) {
            $clearance = Get-MagmaNearestFishDistance $State $position
            $frames = if ($plan.emergency -or $clearance -lt 150) { 8 }
                elseif ($clearance -lt 190) { 12 } else { 24 }
            $next = Swim-Pulse $State $plan.point $frames 2.5 -Returning -TrackFrames
            Add-MagmaReturnObservation $next $State
            if ($next.room -ne $diveRoom -or $next.scene.player.can_use_tool -ne 1) { return $next }
            $progress = (Get-Distance $position $plan.point) - (Get-Distance $next.scene.player $plan.point)
            if ($progress -ge .5) { $stalls = 0 } else { ++$stalls }
            $State = $next
        } else {
            ++$stalls
            $priorFrame = $State.scene.player.frame
            try {
                $next = Wait-DiveSnapshot {
                    param($sample)
                    $sample.scene.player.oxygen -le 0 -or ($sample.scene.player.frame -gt $priorFrame -and
                        $sample.activeInputFrames -eq 0 -and !$sample.flags.transitioning)
                } 'fresh Magma clearance before returning' -AllowIsland -AllowEmptyOxygen -MaxWaitSeconds 1.1
            } catch {
                if ($_.Exception.Message -ne 'Timed out waiting for fresh Magma clearance before returning.') { throw }
                $next = Read-DiveSnapshot
            }
            Add-MagmaReturnObservation $next $State
            $State = $next
        }
        if ($stalls -ge 12) { throw 'No safe Magma retreat step was available after twelve fresh samples.' }
    }
    return $State
}
function Get-MagmaPlasmaBurst([double]$FishDistance, [int]$RequestedFrames, [int]$ChargeFrames) {
    if ($FishDistance -lt 200) { return 0 }
    $available = if ($FishDistance -lt 270) { [Math]::Min(72, $RequestedFrames) } else { $RequestedFrames }
    # Allow a small active beam window after the original gun finishes charging.
    if ($available -lt $ChargeFrames + 8) { return 0 }
    return $available
}

function Get-MagmaBlueTarget($State, $Anchor) {
    $player = $State.scene.player
    $shelter = @{x=$Anchor.x - 6; y=$Anchor.y - 24}
    $maxAim = if ((Get-Distance $player $shelter) -le 85) { 230 } else { 190 }
    return $State.targets.jellyfish | Where-Object {
        if ($null -eq $_.x -or $null -eq $_.y -or [Math]::Abs($_.x - $Anchor.x) -gt 150 -or
            $_.y -lt $Anchor.y - 24 -or $_.y -gt $Anchor.y + 350) { return $false }
        $distance = Get-Distance $player $_
        $distance -ge 112 -and $distance -le $maxAim -and (Test-OceanSegment $State.room $player $_)
    } | Sort-Object { Get-Distance $player $_ } | Select-Object -First 1
}

function Get-MagmaCourse([switch]$East) {
    $route = @{x=204;y=222}, @{x=204;y=266}, @{x=208;y=304}, @{x=212;y=328}, @{x=212;y=344},
        @{x=210;y=370}, @{x=208;y=390}, @{x=204;y=413}, @{x=198;y=437}, @{x=200;y=460}
    $pivots = @{x=171;y=222}, @{x=237;y=240}, @{x=172;y=280}, @{x=242;y=288},
        @{x=178;y=326}, @{x=238;y=344}, @{x=175;y=380}, @{x=217;y=413}, @{x=204;y=413}, @{x=198;y=437},
        @{x=165;y=239}, @{x=152;y=266}, @{x=153;y=288}, @{x=172;y=307}, @{x=187;y=328},
        @{x=275;y=244}, @{x=261;y=264}, @{x=247;y=288}, @{x=230;y=318}
    if ($East) {
        $route = @{x=265;y=152}, @{x=315;y=124}, @{x=378;y=112}, @{x=424;y=112},
            @{x=485;y=128}, @{x=501;y=184}, @{x=508;y=256}, @{x=510;y=320},
            @{x=511;y=358}, @{x=512;y=399}, @{x=514;y=427}
        $pivots = $route + @(@{x=249;y=199}, @{x=496;y=256}, @{x=521;y=320}, @{x=501;y=368})
    }
    return @{route=$route; pivots=$pivots}
}

function Invoke-MagmaWestProbe($State, [ValidateSet('Jellyfish', 'Resource')] [string]$TargetKind) {
    $fish = $TargetKind -eq 'Jellyfish'
    $bubbleFrames = if ($fish) { 30 } else { $HoldFrames }
    $holdDuration = if ($fish) { $bubbleFrames } else { $PlasmaHoldFrames }
    $weapon = if ($fish) { 'bubble' } else { 'plasma' }
    $script:magmaMiningEast = !$fish -and $MagmaMineSector -eq 'East'
    $course = Get-MagmaCourse -East:$script:magmaMiningEast
    $route = $course.route
    $pivots = $course.pivots
    $script:magmaReturnPivots = $pivots
    $script:magmaMinFishClearance = [double]::PositiveInfinity
    $script:magmaPossibleContacts = 0
    $script:magmaPartialRetreats = 0
    $script:magmaMinimumReturnOxygen = $null
    $holdFramesUsed = 0
    $seenOrePositions = [Collections.Generic.List[object]]::new()
    $sameOreShots = 0
    $lastOre = $null
    $targetDistance = $null
    $trialPickup = $false
    $waitedInsideBubble = $false
    $shelteredRetries = 0
    $coverShots = 0
    $skippedPlasmaWindows = 0
    $clearedOre = 0
    $blockedAt = $null
    $trail = [Collections.Generic.List[object]]::new()
    $trail.Add($State.scene.player)
    $startingOxygen = [double]$State.scene.player.oxygen
    $startingProjectiles = $State.projectiles.$weapon
    $maximumDistance = 0.0
    $minimumOxygen = $startingOxygen
    $shots = 0
    $index = 0
    $stalledPulses = 0
    $framesPerPixel = 1.0 / 1.8
    $workBudget = [Math]::Max($HarvestSeconds, 25)
    $deadline = [Math]::Min($TimeoutSeconds - 9, $timer.Elapsed.TotalSeconds + $workBudget)
    $reason = 'magma-harvest-budget'
    $anchor = Get-LiveSubmarine $State
    $firstShotSite = $route[2]
    $center = @{x=$anchor.x - 6; y=$anchor.y - 24}
    if ((Get-Distance $State.scene.player $center) -gt 90) {
        $route = @($center) + $route
    }
    $firstShotDistance = (Get-Distance $State.scene.player $firstShotSite) + (Get-Distance $firstShotSite $anchor)
    if (!$UseSubmarineBubble -or !$nativeTerrain -or !$nativeTerrain[$State.room]) {
        $reason = 'magma-bubble-or-terrain-unavailable'
    } elseif ($State.scene.player.oxygen_max -le (Get-MagmaPressureReserve $firstShotDistance $framesPerPixel $holdDuration)) {
        $reason = 'magma-tank-too-small'
    } else {
        while ($State.room -eq 'rm_ocean_magma_01' -and $State.scene.player.can_use_tool -ne 0 -and
               $timer.Elapsed.TotalSeconds -lt $deadline) {
            $anchor = Get-LiveSubmarine $State
            $player = $State.scene.player
            $returnDistance = Get-Distance $player $anchor
            $maximumDistance = [Math]::Max($maximumDistance, $returnDistance)
            $clearance = Get-MagmaNearestFishDistance $State $player
            $script:magmaMinFishClearance = [Math]::Min($script:magmaMinFishClearance, $clearance)
            $center = @{x=$anchor.x - 6; y=$anchor.y - 24}
            $sheltered = (Get-Distance $player $center) -le 85
            $returnPlan = Get-MagmaPath $State $player $anchor ($pivots + $trail.ToArray()) 8 -TerrainOnly
            if (!$returnPlan -and !$sheltered -and $returnDistance -gt 43) {
                $reason = 'magma-return-path'
                break
            }
            $returnLength = if ($returnPlan) { $returnPlan.distance } else { 0 }
            if ($player.oxygen -le (Get-MagmaPressureReserve $returnLength $framesPerPixel)) {
                $reason = 'magma-return-oxygen'
                break
            }
            $inventory = $State.inventories.player
            if ($fish -and $inventory.slotCount -gt 0 -and $inventory.slotCapacity -gt 0 -and
                $inventory.total -ge $inventory.slotCount * $inventory.slotCapacity) {
                $reason = 'magma-backpack-full'
                break
            }
            if ($lastOre -and !($State.targets.resources | Where-Object {
                $null -ne $_.x -and $null -ne $_.y -and (Get-Distance $_ $lastOre) -lt 20
            } | Select-Object -First 1)) {
                for ($step = 0; $step -lt 9 -and $State.scene.player.can_use_tool -eq 1 -and
                    $timer.Elapsed.TotalSeconds -lt $deadline; ++$step) {
                    $position = $State.scene.player
                    $plan = Get-MagmaPickupPlan $State $lastOre $anchor ($pivots + $trail.ToArray()) $framesPerPixel
                    if (!$plan) { break }
                    $trialPickup = $true
                    $State = Swim-Pulse $State $plan.point 16 2.5 -TrackFrames
                    $trail.Add($State.scene.player)
                    $minimumOxygen = [Math]::Min($minimumOxygen, [double]$State.scene.player.oxygen)
                    $maximumDistance = [Math]::Max($maximumDistance, (Get-Distance $State.scene.player $anchor))
                    $script:magmaMinFishClearance = [Math]::Min($script:magmaMinFishClearance,
                        (Get-MagmaNearestFishDistance $State $State.scene.player))
                    if ($State.scene.player.can_use_tool -eq 0 -and $position.oxygen - $State.scene.player.oxygen -ge $magmaContactDrop) {
                        ++$script:magmaPossibleContacts
                    }
                    if ((Get-Distance $position $plan.point) - (Get-Distance $State.scene.player $plan.point) -lt .5) { break }
                }
                ++$clearedOre
                $seenOrePositions.Add($lastOre)
                $lastOre = $null
                $sameOreShots = 0
                $reason = 'magma-ore-left-native-target-list'
                continue
            }
            $target = if ($fish) {
                Get-MagmaBlueTarget $State $anchor
            } else {
                $State.targets.resources | Where-Object {
                    $oreCandidate = $_
                    if ($null -eq $_.x -or $null -eq $_.y) { return $false }
                    $inSector = if ($script:magmaMiningEast) {
                        $_.x -ge 452 -and $_.x -le 632 -and $_.y -ge 222 -and $_.y -le 493
                    } else {
                        [Math]::Abs($_.x - $anchor.x) -le 100 -and $_.y -ge $anchor.y + 100 -and $_.y -le $anchor.y + 360
                    }
                    $inSector -and
                        (Get-Distance $player $_) -le $MagmaPlasmaAimRange -and
                        (Test-OceanSegment $State.room $player $_) -and !($seenOrePositions | Where-Object {
                            (Get-Distance $_ $oreCandidate) -lt 20
                        } | Select-Object -First 1)
                } | Sort-Object { Get-Distance $player $_ } | Select-Object -First 1
            }
            if ($target) {
                $burst = if ($fish) {
                    if ($clearance -lt 200) { [Math]::Min(16, $holdDuration) } else { $holdDuration }
                } else { Get-MagmaPlasmaBurst $clearance $holdDuration $MagmaPlasmaChargeFrames }
                if (!$fish -and $burst -eq 0) { ++$skippedPlasmaWindows }
                if ($burst -gt 0 -and $clearance -ge 132 -and
                    $player.oxygen -gt (Get-MagmaPressureReserve $returnLength $framesPerPixel $burst)) {
                    if (!$fish) {
                        if (!$lastOre -or (Get-Distance $lastOre $target) -ge 20) { $sameOreShots = 0 }
                        $lastOre = $target
                        ++$sameOreShots
                    }
                    $targetDistance = [Math]::Round((Get-Distance $player $target), 1)
                    $beforeOxygen = $player.oxygen
                    $State = Invoke-DiveTarget $State $target $TargetKind -BubbleFrames $burst -PlasmaFrames $burst
                    ++$shots
                    $holdFramesUsed += $burst
                    $minimumOxygen = [Math]::Min($minimumOxygen, [double]$State.scene.player.oxygen)
                    if ($State.scene.player.can_use_tool -eq 0 -and $beforeOxygen - $State.scene.player.oxygen -ge $magmaContactDrop) {
                        ++$script:magmaPossibleContacts
                    }
                    $reason = "magma-$weapon-hold"
                    if (!$fish -and $sameOreShots -ge 7 -and ($State.targets.resources | Where-Object {
                        (Get-Distance $_ $lastOre) -lt 20
                    } | Select-Object -First 1)) {
                        $seenOrePositions.Add($lastOre)
                        $lastOre = $null
                        $sameOreShots = 0
                    }
                    continue
                }
            }

            $center = @{x=$anchor.x - 6; y=$anchor.y - 24}
            if ($fish -and !$waitedInsideBubble -and (Get-Distance $player $center) -le 85 -and
                (Test-MagmaSwimClear $State $player $player) -and ($State.targets.jellyfish | Where-Object {
                    (Get-Distance $player $_) -lt 240
                } | Select-Object -First 1)) {
                $waitedInsideBubble = $true
                $before = $State.frame
                try {
                    $State = Wait-DiveSnapshot {
                        param($sample)
                        $sample.frame -gt $before -and ($sample.scene.player.can_use_tool -ne 1 -or
                            $sample.scene.player.oxygen -lt $player.oxygen -or (Get-MagmaBlueTarget $sample (Get-LiveSubmarine $sample)))
                    } 'a native Blue target to enter the sheltered firing angle' -MaxWaitSeconds 1.15
                } catch {
                    if ($_.Exception.Message -notlike 'Timed out waiting for a native Blue target*') { throw }
                    $State = Read-DiveSnapshot
                }
                $minimumOxygen = [Math]::Min($minimumOxygen, [double]$State.scene.player.oxygen)
                continue
            }
            while ($index -lt $route.Count -and (Get-Distance $player $route[$index]) -le 14) { ++$index }
            if ($index -eq $route.Count) {
                $reason = if ($fish) { 'magma-no-west-fish-in-range' } else { 'magma-no-ore-in-sector' }
                break
            }
            $point = $route[$index]
            $fromMargin = if (Test-OceanSegment $State.room $player $player 18) { 18 } else { 8 }
            $out = Get-MagmaScoutPlan $State $player $point $pivots $fromMargin
            $exit = if ($out) { Get-MagmaPath $State $point $anchor $pivots 12 -TerrainOnly }
            if (!$out -or !$exit) {
                foreach ($side in ($pivots | Where-Object {
                    $_.y -gt $player.y + 15 -and [Math]::Abs($_.y - $point.y) -le 31
                } | Sort-Object { Get-Distance $player $_ })) {
                    $sidePath = Get-MagmaScoutPlan $State $player $side $pivots $fromMargin
                    $sideExit = if ($sidePath) { Get-MagmaPath $State $side $anchor $pivots 12 -TerrainOnly }
                    if ($sidePath -and $sideExit) {
                        $out = $sidePath
                        $exit = $sideExit
                        break
                    }
                }
            }
            if (!$out -or !$exit) {
                $blockedAt = $point
                $reason = 'magma-no-clear-scout-and-return'
                if (!$sheltered -or $shelteredRetries -ge 5) { break }

                ++$shelteredRetries
                $before = $State
                $coverTarget = if (!$fish -and $clearance -ge 150 -and $coverShots -lt 3) {
                    Get-MagmaBlueTarget $State $anchor
                }
                if ($coverTarget) {
                    $State = Invoke-DiveTarget $State $coverTarget Jellyfish -BubbleFrames 16
                    ++$coverShots
                } elseif ($clearance -lt 145) {
                    $retreat = Get-MagmaRetreatStep $State $center $pivots $fromMargin
                    if (!$retreat) { break }
                    $State = Swim-Pulse $State $retreat.point 10 2.5 -TrackFrames
                    $trail.Add($State.scene.player)
                } else {
                    $freshFrame = $State.frame + 10
                    try {
                        $State = Wait-DiveSnapshot { param($sample) $sample.frame -ge $freshFrame } 'fresh sheltered Magma scouting telemetry' -MaxWaitSeconds .45
                    } catch {
                        if ($_.Exception.Message -notlike 'Timed out waiting for fresh sheltered Magma scouting telemetry*') { throw }
                        $State = Read-DiveSnapshot
                    }
                }
                $minimumOxygen = [Math]::Min($minimumOxygen, [double]$State.scene.player.oxygen)
                if ($State.scene.player.can_use_tool -eq 0 -and
                    $before.scene.player.oxygen - $State.scene.player.oxygen -ge $magmaContactDrop) {
                    ++$script:magmaPossibleContacts
                }
                continue
            }
            $shelteredRetries = 0
            $plannedDistance = $out.distance + $exit.distance
            if ($player.oxygen -le (Get-MagmaPressureReserve $plannedDistance $framesPerPixel)) {
                $reason = 'magma-scout-oxygen'
                break
            }
            $point = $out.point
            $State = Swim-Pulse $State $point $out.frames 2.5 -TrackFrames
            if ($State.scene.player.can_use_tool -eq 0 -and $player.oxygen - $State.scene.player.oxygen -ge $magmaContactDrop) {
                ++$script:magmaPossibleContacts
            }
            $trail.Add($State.scene.player)
            $minimumOxygen = [Math]::Min($minimumOxygen, [double]$State.scene.player.oxygen)
            $distanceMoved = Get-Distance $player $State.scene.player
            $progress = (Get-Distance $player $point) - (Get-Distance $State.scene.player $point)
            if ($progress -lt .5) {
                ++$stalledPulses
                if ($stalledPulses -ge 3) {
                    $reason = 'magma-scout-stalled'
                    break
                }
            } else {
                $stalledPulses = 0
            }
            if ($progress -gt 0 -and $distanceMoved -ge 8 -and $State.swimPulseFrames -gt 0) {
                $measuredFramesPerPixel = $State.swimPulseFrames / $distanceMoved
                $framesPerPixel = [Math]::Max(1.0 / 1.8, .65 * $framesPerPixel + .35 * $measuredFramesPerPixel)
            }
        }
    }
    $oxygenBeforeReturn = [double]$State.scene.player.oxygen
    $finalProjectiles = $State.projectiles.$weapon
    $returned = Return-ToIsland $State $trail
    if ($returned.room -eq 'rm_main_island') { [IO.File]::Delete($returnCheckpoint) }
    $metrics = if ($fish) {
        $bubbleProjectiles = if ($null -ne $startingProjectiles -and $null -ne $finalProjectiles -and $finalProjectiles -ge $startingProjectiles) {
            if ($shots -gt 0) { [long]$finalProjectiles - [long]$startingProjectiles } else { 0 }
        }
        [ordered]@{magmaWestJellyfish=$true; reason=$reason; shots=$shots; bubbleHoldFrames=$holdFramesUsed
            bubbleProjectiles=$bubbleProjectiles; targetDistance=$targetDistance; waitedInsideBubble=$waitedInsideBubble}
    } else {
        [ordered]@{magmaWestResource=(!$script:magmaMiningEast); magmaSector=$MagmaMineSector
            reason=$reason; shots=$shots; plasmaHoldFrames=$holdFramesUsed
            plasmaProjectiles=([long]$finalProjectiles - [long]$startingProjectiles)
            plasmaChargeFrames=$MagmaPlasmaChargeFrames; skippedPlasmaWindows=$skippedPlasmaWindows
            lastOre=$lastOre; targetDistance=$targetDistance; attemptedPickup=$trialPickup}
    }
    $metrics.startingOxygen = $startingOxygen
    $metrics.minimumHarvestOxygen = [Math]::Min($minimumOxygen, $oxygenBeforeReturn)
    $metrics.oxygenBeforeReturn = $oxygenBeforeReturn
    $metrics.minimumReturnOxygen = $script:magmaMinimumReturnOxygen
    $lowestOxygen = if ($null -ne $script:magmaMinimumReturnOxygen) {
        [Math]::Min($metrics.minimumHarvestOxygen, $script:magmaMinimumReturnOxygen)
    } else { $metrics.minimumHarvestOxygen }
    $metrics.oxygenUsedFromStart = $startingOxygen - $lowestOxygen
    $metrics.oxygenAfterReturn = $returned.scene.player.oxygen
    $metrics.maxDistanceFromSubmarine = [Math]::Round($maximumDistance, 1)
    $metrics.swimFramesPerPixel = [Math]::Round($framesPerPixel, 3)
    $metrics.elapsedMs = $timer.ElapsedMilliseconds
    $metrics.minimumObservedFishClearance = if (![double]::IsInfinity($script:magmaMinFishClearance)) {
        [Math]::Round($script:magmaMinFishClearance, 1)
    }
    $metrics.possibleContacts = $script:magmaPossibleContacts
    $metrics.partialRetreatSteps = $script:magmaPartialRetreats
    $metrics.oreTargetsCleared = $clearedOre
    $metrics.coverShots = $coverShots
    $metrics.lastBlockedScout = $blockedAt
    $returned | Add-Member -NotePropertyName autoplayDive -NotePropertyValue ([pscustomobject]$metrics)
    return $returned
}

function Get-SwampSafeReturn([string]$Room, $Position, $Anchor) {
    if (Test-OceanSegment $Room $Position $Anchor 18) {
        return @{distance=(Get-Distance $Position $Anchor); waypoint=$null}
    }
    $waypoints = switch ($Room) {
        'rm_ocean_swamp_02' { @{x=432;y=368}; @{x=480;y=448} }
        'rm_ocean_swamp_03' { @{x=500;y=744}; @{x=552;y=752}; @{x=443;y=801}; @{x=468;y=868}; @{x=414;y=676}; @{x=610;y=760} }
    }
    foreach ($point in $waypoints) {
        if ((Test-OceanSegment $Room $Position $point 18) -and (Test-OceanSegment $Room $point $Anchor 18)) {
            return @{distance=((Get-Distance $Position $point) + (Get-Distance $point $Anchor)); waypoint=$point}
        }
    }
}

function Get-SwampReturnMinimum($State, $Route, $Anchor, [int]$ActionFrames = 0) {
    $openDistance = [Math]::Max(0, $Route.distance - [Math]::Min(72, $Anchor.range))
    $returnFrames = [Math]::Ceiling($openDistance / 1.8) + 44 + (30 * [int][bool]$Route.waypoint)
    $pressure = if ($State.room -eq 'rm_ocean_swamp_03') { 1500 } else { 450 }
    $worstCaseTicks = [Math]::Ceiling(($returnFrames + $ActionFrames) / 40) + 2
    return [Math]::Max(.09 * $State.scene.player.oxygen_max, $pressure * $worstCaseTicks)
}

function Get-SwampBowlTarget($State, $Anchor, $Pool, [string]$TargetKind, $Deprioritized, $RecentCatch) {
    $player = $State.scene.player
    $ring = if ($Anchor.range -gt 0) { $Anchor.range } else { 75 }
    $highPressure = $State.room -eq 'rm_ocean_swamp_03'
    $expandSwampBowl = !$highPressure -and $player.oxygen_max -ge 16000
    $targetRadius = if ($furtherSwampRoute) { 545 }
        elseif ($deeperSwampRoute) { 475 }
        elseif ($highPressure) { $ring + 74 }
        elseif ($expandSwampBowl) { $ring + 188 } else { $ring + 120 }
    $firingRadius = if ($furtherSwampRoute) { 475 }
        elseif ($deeperSwampRoute) { 400 }
        elseif ($highPressure) { [Math]::Max(16, $ring - 8) }
        elseif ($expandSwampBowl) { $ring + 125 } else { $ring + 65 }
    $ore = $TargetKind -eq 'Resource'
    $plannedFrames = if ($ore) { $PlasmaHoldFrames + 30 } else { $HoldFrames + 50 }
    return $Pool | ForEach-Object {
        $target = $_
        if ($null -eq $target.x -or $null -eq $target.y -or (Get-Distance $target $Anchor) -gt $targetRadius -or
            ($RecentCatch -and $State.frame -le $RecentCatch.untilFrame -and (Get-Distance $target $RecentCatch) -le 36)) { return }
        if ($avoidedSwampTarget -and $TargetKind -eq $avoidedSwampTarget.kind -and
            (Get-Distance $target $avoidedSwampTarget) -le 28) { return }
        $distance = Get-Distance $player $target
        $fireAt = if ($ore -and $distance -le 62 -or !$ore -and $distance -ge 48 -and $distance -le 82) { $player }
            elseif ($ore) { Get-StandOffPoint $player $target $distance 54 }
            else { Get-StandOffPoint $player $target $distance }
        if (!$fireAt) { return }
        $anchorDistance = Get-Distance $fireAt $Anchor
        if ($anchorDistance -gt $firingRadius -or !(Test-OceanSegment $State.room $player $target) -or
            !(Test-OceanSegment $State.room $player $fireAt 18)) { return }
        $route = if ($furtherSwampRoute) { Get-SwampSafeReturn $State.room $fireAt $Anchor }
            elseif (Test-OceanSegment $State.room $fireAt $Anchor 18) { @{distance=$anchorDistance} }
        if (!$route -or ($deeperSwampRoute -and $player.oxygen -le (Get-SwampReturnMinimum $State $route $Anchor $plannedFrames))) { return }
        [pscustomobject]@{
            target = $target
            deprioritized = $Deprioritized -and (Get-Distance $target $Deprioritized) -lt 32
            outsideRing = [Math]::Max(0, $anchorDistance - $ring)
            swimDistance = Get-Distance $player $fireAt
            targetDistance = $distance
        }
    } | Sort-Object deprioritized, outsideRing, swimDistance, targetDistance | Select-Object -First 1 -ExpandProperty target
}

function Get-LongShelfResourcePlan($State, $Anchor) {
    $player = $State.scene.player
    $ice = $State.room -eq 'rm_ocean_glacial_02'
    $range = $MagmaPlasmaAimRange
    $pickupRange = if ($ice) { 30 } else { 46 }
    $margin = if ($ice) { 14 } else { 18 }
    $targetRadius = if ($ice) { 565 } elseif ($furtherSwampRoute) { 545 } else { $Anchor.range + 74 }
    $returnRadius = if ($furtherSwampRoute) { 475 } else { [Math]::Max(16, $Anchor.range - 8) }

    return $State.targets.resources | ForEach-Object {
        $target = $_
        if ($null -eq $target.x -or $null -eq $target.y -or
            (Get-Distance $target $Anchor) -gt $targetRadius) { return }
        if ($ice -and ($target.x -lt 512 -or $target.x -gt 690 -or $target.y -lt 368 -or $target.y -gt 470)) { return }
        if (!(Test-OceanSegment $State.room $player $target)) { return }

        $distance = Get-Distance $player $target
        $fireAt = if ($distance -le $range) { $player } else { Get-StandOffPoint $player $target $distance ($range - 10) }
        $pickup = if ($distance -le $pickupRange) { $player } else {
            Get-StandOffPoint $player $target $distance $pickupRange
        }
        if (!$fireAt -or !$pickup -or !(Test-OceanSegment $State.room $player $pickup $margin)) { return }

        if ($ice) {
            # Keep both the launch and collection on the original west shelf return corridor.
            $corridor = @{x=$pickup.x;y=379}
            $west = @{x=220;y=379}
            if (!(Test-OceanSegment $State.room $pickup $corridor $margin) -or
                !(Test-OceanSegment $State.room $corridor $west $margin) -or
                !(Test-OceanSegment $State.room $west $Anchor $margin)) { return }
        } else {
            if ((Get-Distance $pickup $Anchor) -gt $returnRadius) { return }
            $route = Get-SwampSafeReturn $State.room $pickup $Anchor
            $actionFrames = $PlasmaHoldFrames + [Math]::Ceiling((Get-Distance $player $pickup) / 1.8) + 30
            if (!$route -or $player.oxygen -le (Get-SwampReturnMinimum $State $route $Anchor $actionFrames)) { return }
        }
        [pscustomobject]@{
            target=$target; range=$range; fireAt=$fireAt; pickup=$pickup
            distance=$distance; approachDistance=(Get-Distance $player $fireAt)
            collectionDistance=(Get-Distance $player $pickup)
        }
    } | Sort-Object approachDistance, collectionDistance, distance | Select-Object -First 1
}

function Get-NearbyTarget($State, [string]$TargetKind, $Deprioritized, $RecentCatch) {
    $pool = if ($TargetKind -eq 'Resource') { $State.targets.resources } else { $State.targets.jellyfish }
    $anchor = Get-LiveSubmarine $State
    if ($State.room -in 'rm_ocean_swamp_02', 'rm_ocean_swamp_03') {
        return Get-SwampBowlTarget $State $anchor $pool $TargetKind $Deprioritized $RecentCatch
    }
    $radius = if ($TargetKind -eq 'Resource') { 340 } else { 260 }
    if ($State.room -ne 'rm_ocean_shallows_01' -and $State.scene.player.oxygen_max -ge 400) { $radius += 110 }
    $conserveGlacialOxygen = $TargetKind -eq 'Jellyfish' -and $State.room -like 'rm_ocean_glacial_*' -and
        $State.scene.player.oxygen_max -lt 1600
    if ($conserveGlacialOxygen) { $radius = [Math]::Min($radius, 180) }

    $useGlacialOreShelf = $TargetKind -eq 'Resource' -and $State.room -eq 'rm_ocean_glacial_02'
    $fishBounds = if ($TargetKind -eq 'Jellyfish') {
        switch ($State.room) {
            'rm_ocean_glacial_01' { @{left=110;right=570;top=220;bottom=425} }
            'rm_ocean_glacial_02' { @{left=145;right=310;top=275;bottom=435} }
            'rm_ocean_glacial_03' { @{left=335;right=700;top=80;bottom=310} }
            'rm_ocean_swamp_01'   { @{left=55;right=625;top=135;bottom=440} }
        }
    }
    $useSwampMushroomShelf = $TargetKind -eq 'Resource' -and $State.room -eq 'rm_ocean_swamp_01'
    if ($useGlacialOreShelf) { $radius = 565 }
    if ($useSwampMushroomShelf -or ($fishBounds -and $State.room -eq 'rm_ocean_swamp_01')) { $radius = 500 }
    if ($fishBounds -and $State.room -eq 'rm_ocean_glacial_01' -and !$conserveGlacialOxygen) { $radius = 480 }
    $preferBubbleShelter = $UseSubmarineBubble -and $fishBounds
    return $pool | Where-Object {
        $null -ne $_.x -and $null -ne $_.y -and (Get-Distance $_ $anchor) -le $radius -and
            (!$RecentCatch -or $State.frame -gt $RecentCatch.untilFrame -or (Get-Distance $_ $RecentCatch) -gt 36) -and

            (!$useGlacialOreShelf -or ($_.x -ge 512 -and $_.x -le 690 -and $_.y -ge 368 -and $_.y -le 470)) -and
            (!$useSwampMushroomShelf -or ($_.x -ge 182 -and $_.x -le 625 -and $_.y -ge 270 -and $_.y -le 480 -and
                (Test-SwampOreAccess $State $_))) -and
            (!$fishBounds -or ($_.x -ge $fishBounds.left -and $_.x -le $fishBounds.right -and
                $_.y -ge $fishBounds.top -and $_.y -le $fishBounds.bottom -and
                (Test-FishAccess $State $_)))
    } | Sort-Object { $Deprioritized -and (Get-Distance $_ $Deprioritized) -lt 32 },
        {
            if ($preferBubbleShelter) {
                $distance = Get-Distance $_ $State.scene.player
                $fireAt = if ($distance -ge 48 -and $distance -le 82) { $State.scene.player }
                    else { Get-StandOffPoint $State.scene.player $_ $distance }
                return !$fireAt -or (Get-Distance $fireAt $anchor) -gt 82
            }
            return $false
        },
        { Get-Distance $_ $State.scene.player } | Select-Object -First 1
}

function Wait-ForSubmarineToSettle($State) {
    $previous = $State
    $stable = 0
    $deadline = [Math]::Min($TimeoutSeconds, $timer.Elapsed.TotalSeconds + 3.5)
    while ($timer.Elapsed.TotalSeconds -lt $deadline) {
        $sample = Read-DiveSnapshot
        if ($sample.room -ne $diveRoom) { return $sample }
        if (!$BeforeDiveSaveHash -and (Test-IdleDiveModal $sample)) { return $sample }
        if ($sample.frame -gt $previous.frame) {
            $anchor = Get-LiveSubmarine $sample
            if ($sample.scene.player.can_use_tool -eq 1 -and $previous.scene.player.can_use_tool -eq 1 -and
                (Get-Distance $anchor $previous.scene.submarineLeave) -lt 1.5 -and
                (Get-Distance $sample.scene.player $previous.scene.player) -lt 1.5 -and !$sample.flags.transitioning) {
                ++$stable
                if ($stable -ge 2 -and ($sample.targets.jellyfish -or $sample.targets.resources)) { return $sample }
            } else {
                $stable = 0
            }
            $previous = $sample
        }
        Start-Sleep -Milliseconds 70
    }
    return $previous
}

function Invoke-DiveTarget($State, $Target, [string]$TargetKind, [int]$BubbleFrames = $HoldFrames,
                           [int]$PlasmaFrames = $PlasmaHoldFrames) {
    if ($TargetKind -eq 'Resource') {
        $duration = $PlasmaFrames
        $aim = @{worldX=$Target.x; worldY=$Target.y; holdFrames=($duration+60)} | ConvertTo-Json -Compress
        $null = & $control -Action aim -ParametersJson $aim -Mailbox $Mailbox -TimeoutSeconds (Get-CommandTimeout)
        return Invoke-DiveCommand $State input @{frames=$duration; values=@{use_plasma_gun=1}} $duration
    }
    return Invoke-DiveCommand $State click @{
        worldX = $Target.x
        worldY = $Target.y
        button = 1
        holdFrames = $BubbleFrames
    } ($BubbleFrames + 8)
}

function Read-DiveSaveHash {
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($SavePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $saveBytes = $memory.ToArray()
        } finally {
            $memory.Dispose()
            $stream.Dispose()
        }
        $text = [Text.Encoding]::UTF8.GetString($saveBytes).Trim()
        if (!$text.StartsWith('{')) {
            $binary = [Convert]::FromHexString($text)
            if ($binary.Length -lt 16) { return }
            $length = [BitConverter]::ToInt32($binary, 12)
            if ($length -le 0 -or $length -ne ($binary.Length - 16)) { return }
            $text = [Text.Encoding]::UTF8.GetString($binary, 16, $length)
        }
        $parsed = ConvertFrom-Json -InputObject $text
        if ($parsed.global) { $parsed = $parsed.global }
        if ($null -eq $parsed.shell_coins -or $null -eq $parsed.scrap_coins) { return }
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($saveBytes))
    } catch {
        return
    }
}

function Write-ReturnCheckpoint($State, [string]$ExpectedHash) {
    $temporary = "$returnCheckpoint.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        @{
            pid=$gamePid; beforeHash=$diveSaveHash; expectedHash=$ExpectedHash; stateFrame=$State.frame;
            x=$State.scene.player.x; y=$State.scene.player.y; oxygen=$State.scene.player.oxygen
        } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding utf8
        Publish-ShelldiverMailboxFile $temporary $returnCheckpoint
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Test-IdleDiveModal($State, [switch]$SavedInventoryResult) {
    return $State.room -eq $diveRoom -and $State.scene.player.can_use_tool -eq 0 -and
        $State.activeInputFrames -eq 0 -and !$State.flags.pause -and
        (!$State.flags.player_inventory_open -or $SavedInventoryResult) -and !$State.flags.transitioning -and
        !$State.guiPointer.active -and $State.guiPointer.buttonHooks
}

function Get-ConfirmedSaveHash {
    $candidate = Read-DiveSaveHash
    if ($candidate -and $candidate -ne $diveSaveHash) { return $candidate }
}

function Wait-ReturnStage($State, [double]$Seconds, [string]$Expected) {
    $deadline = [Math]::Min($diveDeadline, $timer.Elapsed.TotalSeconds + $Seconds)
    $previousModal = $null
    while ($timer.Elapsed.TotalSeconds -lt $deadline) {
        $next = Read-DiveSnapshot
        if ($next.room -eq 'rm_main_island') { return $next }
        # Original Expedition End can keep the automatic full-pack inventory flag active.
        # Accept that specific overlay only after this return produced a new native save.
        $savedInventoryResult = $next.flags.player_inventory_open -and $Expected -in 'save','result' -and
            $next.scene.player.can_use_tool -eq 0 -and (Get-ConfirmedSaveHash)
        if ($next.frame -gt $State.frame -and (Test-IdleDiveModal $next -SavedInventoryResult:$savedInventoryResult)) {
            if ($Expected -eq 'save' -and (Get-ConfirmedSaveHash)) { return $next }
            if ($previousModal -and $next.frame -gt $previousModal.frame) {
                $oxygenSettled = [Math]::Abs($next.scene.player.oxygen - $previousModal.scene.player.oxygen) -lt 0.01
                if ($oxygenSettled -and $Expected -eq 'prompt' -and $next.scene.player.oxygen -gt 0 -and
                    (Get-Distance $next.scene.player $previousModal.scene.player) -lt 1) {
                    $anchor = Get-LiveSubmarine $next
                    $range = if ($anchor.range -gt 0) { $anchor.range } else { 75 }
                    if ((Get-Distance $next.scene.player $anchor) -le $range) { return $next }
                }
                if ($oxygenSettled -and $Expected -eq 'result' -and $next.frame -ge $State.frame + 12) { return $next }
            }
            if (!$previousModal -or $next.frame -gt $previousModal.frame) { $previousModal = $next }
        } else {
            $previousModal = $null
        }
        Start-Sleep -Milliseconds 20
    }
    Write-Verbose "No return stage '$Expected' at frame $($next.frame). Oxygen $($next.scene.player.oxygen), tools $($next.scene.player.can_use_tool), flags $($next.flags | ConvertTo-Json -Compress), input $($next.activeInputFrames), pointer $($next.guiPointer.active)/$($next.guiPointer.buttonHooks), diver ($($next.scene.player.x), $($next.scene.player.y))."
}

function Open-NativeReturn($State, $Trail) {
    foreach ($count in 3, 5, 5) {
        $oxygen = Get-OxygenPercent $State
        if ($State.scene.player.can_use_tool -eq 0 -or $oxygen -le 0 -or (Get-ConfirmedSaveHash)) { return $State }
        if ($count -gt 3 -and $oxygen -le 8) { return $State }
        if ($null -eq $State.scene.player.frame -or $State.frame -lt $State.scene.player.frame -or $State.frame - $State.scene.player.frame -gt 45) {
            throw 'No current diver frame for native submarine interaction.'
        }
        $anchor = Get-LiveSubmarine $State
        $range = if ($anchor.range -gt 0) { $anchor.range } else { 75 }
        if ($anchor.can_be_used -eq $false) { throw 'The native submarine interaction is unavailable.' }
        if ((Get-Distance $State.scene.player $anchor) -ge ($range - 12)) {
            $State = Swim-BackToSubmarine $State $anchor ([Math]::Min(35, $range - 16)) $Trail
            if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0 -or
                $State.scene.player.oxygen -le 0) { return $State }
            $anchor = Get-LiveSubmarine $State
            if (!$anchor.can_be_used -or (Get-Distance $State.scene.player $anchor) -ge $range) {
                throw 'The diver is outside the native submarine interaction area after reapproaching.'
            }
        }
        $oxygenBeforeInteract = $State.scene.player.oxygen
        $State = Invoke-DiveCommand $State input @{frames=$count; values=@{interact=1; interact_hold=$true}} $count `
            -AllowIsland -ResultStage -MaxWaitSeconds 0.85 -AckTimeout 1
        if ($State.room -eq 'rm_main_island') { return $State }
        if ($magmaScout -and $oxygenBeforeInteract - $State.scene.player.oxygen -ge $magmaContactDrop) {
            $State = Wait-MagmaDiverReadyForReturn $State
        }
    }
    return $State
}

function Swim-BackToSubmarine($State, $Anchor, [double]$TargetDistance, $Trail) {
    if ($dynamicMagma) { return Swim-DynamicMagmaHome $State $TargetDistance $Trail }
    if ($magmaScout) { return Swim-MagmaSafeReturn $State $TargetDistance (@($script:magmaReturnPivots) + @($Trail)) }
    try {
        $position = $State.scene.player
        if ($State.room -eq 'rm_ocean_shallows_03' -and $Anchor.x -lt 592 -and
            $position.x -ge 640 -and $position.x -lt 720 -and $position.y -ge 196 -and $position.y -lt 240) {
            # The Shallows wall reaches y208. Cross on its upper side.
            $State = Swim-To $State @{x=$position.x;y=172} 8 -Backtrack
            if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
            $Anchor = Get-LiveSubmarine $State
        }
        if ($State.room -eq 'rm_ocean_glacial_01' -and $Anchor.x -lt 270 -and
            $position.x -ge 272 -and $position.x -lt 590 -and $position.y -ge 294 -and $position.y -lt 390) {
            # Go below the glacial shelf before moving up the west shaft.
            $clearanceY = [Math]::Clamp([double]$position.y, 320, 368)
            $State = Swim-To $State @{x=$position.x;y=$clearanceY} 8 -Backtrack
            if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
            $State = Swim-To $State @{x=224;y=$clearanceY} 10 -Backtrack
            if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
            $Anchor = Get-LiveSubmarine $State
        }
        if ($State.room -eq 'rm_ocean_glacial_02' -and $Anchor.x -lt 280 -and
            $position.x -ge 305 -and $position.x -lt 720 -and $position.y -ge 330 -and $position.y -le 490) {
            # Reach the corridor above the lower wall before crossing the native ore shelf.
            $corridorX = if ($position.x -ge 480 -and $position.x -le 518 -and $position.y -gt 405) { 506 }
                else { $position.x }
            $State = Swim-To $State @{x=$corridorX;y=379} 8 -Backtrack
            if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
            foreach ($x in 410,330,230) {
                if ($State.scene.player.x -le $x + 10) { continue }
                $point = @{x=$x;y=383}
                if (!(Test-OceanSegment $State.room $State.scene.player $point 8)) {
                    throw "Could not swim toward ($x, 383) without crossing the glacial wall."
                }
                $State = Swim-To $State $point 12 -Backtrack
                if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
            }
            $Anchor = Get-LiveSubmarine $State
        }
        if ($State.room -eq 'rm_ocean_swamp_01' -and $Anchor.x -lt 250 -and $position.x -ge 300) {
            $corridor = @{x=$position.x;y=352}
            $west = @{x=216;y=352}
            if ((Test-OceanSegment $State.room $position $corridor 14) -and
                (Test-OceanSegment $State.room $corridor $west 14)) {
                $State = Swim-To $State $corridor 8 -Backtrack
                if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
                $State = Swim-To $State $west 12 -Backtrack
                if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
                $Anchor = Get-LiveSubmarine $State
            }
        }
        if ($State.room -in 'rm_ocean_swamp_02','rm_ocean_swamp_03' -and $nativeTerrain) {
            $route = Get-SwampSafeReturn $State.room $State.scene.player $Anchor
            if ($route.waypoint) {
                $State = Swim-To $State $route.waypoint 10 -Backtrack
                if ($State.room -eq 'rm_main_island' -or $State.scene.player.can_use_tool -eq 0) { return $State }
                $Anchor = Get-LiveSubmarine $State
            }
        }
        return Swim-To $State $Anchor $TargetDistance -Returning
    } catch {
        if (!$Trail -or $Trail.Count -lt 2 -or $_.Exception.Message -notlike 'Could not swim toward*') { throw }
        Write-Verbose 'The direct route stopped making progress. Retracing observed outbound positions.'
    }
    $State = Read-DiveSnapshot
    for ($index = $Trail.Count - 1; $index -ge 0; $index--) {
        if ($State.room -eq 'rm_main_island' -or $State.scene.player.oxygen -le 0) { return $State }
        $Anchor = Get-LiveSubmarine $State
        if ($State.scene.player.can_use_tool -eq 0 -or (Get-Distance $State.scene.player $Anchor) -le $TargetDistance) {
            return $State
        }
        $point = $Trail[$index]
        if ((Get-Distance $State.scene.player $point) -le 8) { continue }
        try {
            $State = Swim-To $State $point 8 -Backtrack
        } catch {
            if ($_.Exception.Message -notlike 'Could not swim toward*') { throw }
            $State = Read-DiveSnapshot
        }
    }
    if ($State.room -eq 'rm_main_island' -or $State.scene.player.oxygen -le 0) { return $State }
    return Swim-To $State (Get-LiveSubmarine $State) $TargetDistance -Returning
}

function Wait-MagmaDiverReadyForReturn($State) {
    if (!$magmaScout -or $State.room -ne $diveRoom -or $State.scene.player.oxygen -le 0 -or
        $State.scene.player.can_use_tool -eq 1) { return $State }
    if ($dynamicMagma) { return Wait-DynamicMagmaAfterHit $State }
    return Wait-DiveSnapshot {
        param($sample)
        $sample.frame -gt $State.frame -and $sample.scene.player.can_use_tool -eq 1 -and
            $sample.activeInputFrames -eq 0 -and !$sample.flags.transitioning
    } 'the Magma diver to recover from a native hit before interacting' -AllowIsland -MaxWaitSeconds 1.2
}

function Return-ToIsland($State, $Trail, [switch]$Reapproached) {
    Update-DiveFullObservation $State
    $script:diveDocking = $true
    if ($script:diveFull -and !$script:diveFull.returnRequestedFrame) { $script:diveFull.returnRequestedFrame = $State.frame }
    if ($State.room -eq 'rm_main_island') { return $State }
    if ($dynamicMagma -and $State.flags.player_inventory_open) {
        $State = Close-DynamicMagmaInventory $State
        if ($State.room -eq 'rm_main_island') { return $State }
    }
    if ($State.flags.player_inventory_open) {
        $State = Invoke-DiveCommand $State input @{frames=1; values=@{open_inventory=1}} 1 -AllowIsland -ResultStage
        if ($State.room -eq 'rm_main_island') { return $State }
        if ($State.flags.player_inventory_open) {
            $State = Invoke-DiveCommand $State input @{frames=1; values=@{back=1; ui_back=$true}} 1 -AllowIsland -ResultStage
            if ($State.room -eq 'rm_main_island') { return $State }
        }
        if ($State.flags.player_inventory_open) { throw 'The native inventory remained open before returning.' }
    }
    $confirmedHash = Get-ConfirmedSaveHash
    $confirmed = ($confirmedHash -and (Test-IdleDiveModal $State)) -or ($ResultVerified -and (Test-IdleDiveModal $State))
    if (!$confirmed) {
        if ($State.scene.player.oxygen -le 0) { throw 'The expedition has run out of oxygen without a confirmed native result.' }
        $State = Wait-MagmaDiverReadyForReturn $State
        if ($State.room -eq 'rm_main_island') { return $State }
        if ($State.scene.player.can_use_tool -ne 0) {
            $diveSaveHash = Read-DiveSaveHash
            if (!$diveSaveHash) { throw 'Could not read the native save before returning.' }
            $anchor = Get-LiveSubmarine $State
            $targetDistance = if ($anchor.range -gt 40) { [Math]::Min(45, $anchor.range - 16) } else { 20 }
            if ($diveRoom -in 'rm_ocean_magma_02','rm_ocean_magma_03') { $targetDistance = [Math]::Min(28,$targetDistance) }
            if ($ReturnApproachDistance -gt 0) { $targetDistance = [Math]::Min($targetDistance, $ReturnApproachDistance) }
            # Use the original interaction radius when already well inside it.
            # Steering closer from inside air can pin the diver between fish and the hatch.
            $insideHatch = $anchor.can_be_used -and $State.scene.player.can_use_tool -eq 1 -and !$State.flags.player_inventory_open -and $anchor.range -ge 40 -and
                (Get-Distance $State.scene.player $anchor) -le $anchor.range-24
            if (!$insideHatch) { $State = Swim-BackToSubmarine $State $anchor $targetDistance $Trail }
            if ($State.room -eq 'rm_main_island') { return $State }
            $State = Wait-MagmaDiverReadyForReturn $State
            if ($State.room -eq 'rm_main_island') { return $State }
            if ($State.scene.player.can_use_tool -ne 0 -and $State.scene.player.oxygen -gt 0) {
                $diveSaveHash = Read-DiveSaveHash
                if (!$diveSaveHash) { throw 'Could not read the native save before submarine interaction.' }
                Write-ReturnCheckpoint $State ''
                $State = Open-NativeReturn $State $Trail
                if ($State.room -eq 'rm_main_island') { return $State }
            }
        }

        if ($State.scene.player.can_use_tool -ne 0 -and $State.scene.player.oxygen -gt 0 -and !(Get-ConfirmedSaveHash)) {
            throw 'The native submarine confirmation did not open after the guarded interaction pulses.'
        }
        $magmaReturn = $State.room -like 'rm_ocean_magma_*'
        $settled = if (!$magmaReturn -or (Get-ConfirmedSaveHash)) { Wait-ReturnStage $State 0.65 'save' }
        if ($settled) {
            if ($settled.room -eq 'rm_main_island') { return $settled }
            $State = $settled
        } else {
            $promptSeconds = if ($diveRoom -eq 'rm_ocean_magma_02') { .85 } else { 3.0 }
            $prompt = Wait-ReturnStage $State $promptSeconds 'prompt'
            if ($prompt -and $prompt.room -eq 'rm_main_island') { return $prompt }
            $confirmedHash = Get-ConfirmedSaveHash
            if (!$confirmedHash) {
                if (!$prompt) {
                    if (($dynamicMagma -or $diveRoom -in 'rm_ocean_magma_02','rm_ocean_magma_03') -and !$Reapproached) {
                        $fresh = Read-DiveSnapshot
                        if ($fresh.room -eq 'rm_main_island') { return $fresh }
                        if ($fresh.scene.player.oxygen -gt 0) {
                            $fresh = Wait-MagmaDiverReadyForReturn $fresh
                            return Return-ToIsland $fresh $Trail -Reapproached
                        }
                    }
                    throw 'The native submarine confirmation did not open.'
                }
                $anchor = Get-LiveSubmarine $prompt
                $range = if ($anchor.range -gt 0) { $anchor.range } else { 75 }
                if ((Get-Distance $prompt.scene.player $anchor) -gt $range) {
                    throw 'The inactive diver is outside the native submarine confirmation range.'
                }
                Write-ReturnCheckpoint $prompt ''
                $State = Invoke-DiveCommand $prompt click @{x=$ConfirmX; y=$ConfirmY; button=1; holdFrames=1} 9 -AllowIsland -ResultStage
                if ($State.room -eq 'rm_main_island') { return $State }
                $settled = Wait-ReturnStage $State 2.5 'save'
                if (!$settled) { throw 'The submarine confirmation produced no native save change.' }
                if ($settled.room -eq 'rm_main_island') { return $settled }
                $State = $settled
            } elseif ($prompt) {
                $State = $prompt
            }
        }
        $confirmedHash = Get-ConfirmedSaveHash
        if (!$confirmedHash) { throw 'The native expedition save has not confirmed the result.' }
    }

    if ($confirmedHash) { Write-ReturnCheckpoint $State $confirmedHash }
    $result = Wait-ReturnStage $State 1.5 'result'
    if (!$result) { throw 'The native expedition result did not become idle.' }
    if ($result.room -eq 'rm_main_island' -or $HoldResult) { return $result }
    for ($attempt = 0; $attempt -lt 2; ++$attempt) {
        $result = Invoke-DiveCommand $result click @{x=0.354; y=0.732; button=1; holdFrames=1} 9 -AllowIsland -ResultStage
        if ($result.room -eq 'rm_main_island') { return $result }
        $island = Wait-ReturnStage $result 1.25 'island'
        if ($island) { return $island }
        if ($attempt -eq 0 -and (Get-ConfirmedSaveHash)) {
            $result = Wait-ReturnStage $result 1.0 'result'
            if ($result -and $result.room -eq 'rm_main_island') { return $result }
            if (!$result) { break }
        } else {
            break
        }
    }
    throw 'The confirmed native expedition result did not return to the island.'
}
$hasX = $PSBoundParameters.ContainsKey('X')
$hasY = $PSBoundParameters.ContainsKey('Y')
if ($hasX -ne $hasY -or ($Action -eq 'Move' -and !$hasX)) { throw 'Pass both -X and -Y for an explicit dive coordinate.' }
$hasConfirmation = $PSBoundParameters.ContainsKey('ConfirmX')
if ($hasConfirmation -ne $PSBoundParameters.ContainsKey('ConfirmY')) { throw 'Pass both -ConfirmX and -ConfirmY.' }
$initial = Read-DiveSnapshot
if (!$diveRooms.ContainsKey([string]$initial.room) -or !$initial.pid) { throw 'Start in a supported native expedition.' }
$diveRoom = $initial.room
if ($mixed -and $diveRoom -notin $regions[700].room, $regions[800].room, $regions[900].room) {
    throw 'Mixed harvesting is supported at 700, 800 and 900 meters.'
}
if ($diveRoom -in $regions[800].room, $regions[900].room -and $Action -in 'Dive', 'Target' -and
    (!$nativeTerrain -or !$nativeTerrain[$diveRoom])) {
    throw 'Harvesting in this room requires the verified original terrain map.'
}
$bounds = $diveRooms[$diveRoom]
if ($hasX -and ($X -gt $bounds.width -or $Y -gt $bounds.height)) { throw 'The target is outside the current ocean room.' }
$gamePid = $initial.pid
$script:diveEntryFrame = if ($MagmaBeforeEntryFrame -gt 0) { $MagmaBeforeEntryFrame } else { [long]$initial.frame-1 }
$script:diveFull = $null
$script:diveDocking = $false
$script:nextFullBadgeMs = 0
Update-DiveFullObservation $initial
$currentSaveHash = Read-DiveSaveHash
if (!$currentSaveHash) { throw "Could not read the native Shelldiver save at '$SavePath'." }
$diveSaveHash = if ($BeforeDiveSaveHash) { $BeforeDiveSaveHash } else { $currentSaveHash }
if (!$BeforeDiveSaveHash -and (Test-IdleDiveModal $initial) -and [IO.File]::Exists($returnCheckpoint)) {
    $checkpoint = Get-Content -LiteralPath $returnCheckpoint -Raw | ConvertFrom-Json
    if ($checkpoint.pid -eq $gamePid -and $checkpoint.stateFrame -le $initial.frame -and
        $null -ne $checkpoint.x -and $null -ne $checkpoint.y -and $null -ne $checkpoint.oxygen -and
        (Get-Distance $checkpoint $initial.scene.player) -le 3 -and
        [Math]::Abs($checkpoint.oxygen - $initial.scene.player.oxygen) -le 3 -and
        (!$checkpoint.expectedHash -or $checkpoint.expectedHash -eq $currentSaveHash)) {
        $diveSaveHash = $checkpoint.beforeHash
    }
}
if ($initial.scene.player.oxygen -le 0 -and !$ResultVerified -and !(Get-ConfirmedSaveHash)) {
    throw 'The expedition has run out of oxygen.'
}

$initialAnchor = Get-LiveSubmarine $initial
$magmaIResource = $diveRoom -eq 'rm_ocean_magma_01' -and $Kind -eq 'Resource'
$dynamicMagmaRoom = $magmaIResource -or $diveRoom -in 'rm_ocean_magma_02','rm_ocean_magma_03'
$magmaExpedition = $Action -eq 'Dive' -and $dynamicMagmaRoom -and $Kind -in 'Resource','Jellyfish'
$magmaRecovery = $Action -eq 'Return' -and ($RecoverMagma -or ($diveRoom -eq 'rm_ocean_magma_03' -and $RequireLiveDiver)) -and
    $diveRoom -in 'rm_ocean_magma_01','rm_ocean_magma_02','rm_ocean_magma_03'
$magmaScout = ($Action -eq 'Dive' -and $diveRoom -eq 'rm_ocean_magma_01') -or $magmaExpedition -or $magmaRecovery
$dynamicMagma = $dynamicMagmaRoom -and ($magmaExpedition -or $magmaRecovery) -and $nativeTerrain -and $nativeTerrain[$diveRoom]
if ($diveRoom -eq 'rm_ocean_magma_03' -and ($magmaExpedition -or $magmaRecovery)) {
    if (!$dynamicMagma) { throw 'Magma Abyss at 1200m requires the verified original terrain map.' }
    if ($FillBackpack -and !$UseSubmarineBubble) { throw 'Filling the backpack at 1200m requires the original Submarine Recover I skill.' }
}
if ($magmaIResource -and ($magmaExpedition -or $magmaRecovery) -and !$dynamicMagma) {
    throw 'Magma I resource mining requires the verified original terrain map.'
}
$shelfResourceRoom = $diveRoom -in 'rm_ocean_glacial_02','rm_ocean_swamp_03'
$verifiedShelfPlasma = $shelfResourceRoom -and $PSBoundParameters.ContainsKey('MagmaPlasmaChargeFrames')
if ($Action -in 'Dive','Target' -and $Kind -in 'Resource','Mixed' -and $PlasmaHoldFrames -lt 100 -and
    ((!$verifiedShelfPlasma -and $diveRoom -notin 'rm_ocean_magma_01','rm_ocean_magma_03') -or
        $Kind -ne 'Resource' -or $PlasmaHoldFrames -lt $MagmaPlasmaChargeFrames+11)) {
    throw 'A short plasma pulse requires a supported resource expedition and at least the native charge plus eleven steps.'
}
if ($magmaExpedition -or $dynamicMagma) { . (Join-Path $PSScriptRoot 'ShelldiverMagmaII.ps1') }
if ($dynamicMagma) {
    . (Join-Path $PSScriptRoot 'ShelldiverDynamicMagma.ps1')
    Initialize-DynamicMagmaRoute
    if ($diveRoom -eq 'rm_ocean_magma_03') { $magmaContactDrop = Get-DynamicMagmaContactDamage 200000 }
    if ($magmaIResource) { $magmaContactDrop = Get-DynamicMagmaContactDamage 20000 }
}
if ($magmaRecovery) {
    $script:magmaMiningEast = $MagmaMineSector -eq 'East'
    $script:magmaReturnPivots = if ($diveRoom -eq 'rm_ocean_magma_02') {
        @{x=400;y=119},@{x=365;y=117},@{x=524;y=116},@{x=574;y=163},@{x=620;y=118},
        @{x=284;y=119},@{x=154;y=119},@{x=156;y=212},@{x=276;y=268}
    } elseif ($diveRoom -eq 'rm_ocean_magma_01' -and !$dynamicMagma) { (Get-MagmaCourse -East:$script:magmaMiningEast).pivots }
    $script:magmaMinFishClearance = [double]::PositiveInfinity
    $script:magmaPossibleContacts = 0
    $script:magmaPartialRetreats = 0
    $script:magmaMinimumReturnOxygen = $null
}
$state = Wait-DiveSnapshot {
    param($sample)
    if ($sample.frame -ge $initial.frame + 45 -and $sample.scene.submarineLeave.frame -le $initialAnchor.frame) {
        throw 'The submarine telemetry stopped advancing. This bridge may only record object creation.'
    }
    $sample.frame -gt $initial.frame -and $sample.inputReady -and $sample.activeInputFrames -eq 0 -and
        (!($RequireLiveDiver -or $magmaScout) -or ($sample.scene.player.oxygen -gt 0 -and
            !$sample.flags.transitioning -and $sample.scene.submarineLeave.can_be_used -and
            (!$RecoverMagma -or $diveRoom -ne 'rm_ocean_magma_03' -or !$sample.flags.pause) -and
            ($sample.scene.player.can_use_tool -eq 1 -or ($RecoverMagma -and $diveRoom -eq 'rm_ocean_magma_03')))) -and
        $null -ne $sample.scene.player.x -and $null -ne $sample.scene.player.y -and
        $null -ne $sample.scene.player.oxygen -and
        $sample.scene.submarineLeave.frame -gt $initialAnchor.frame -and
        $sample.frame - $sample.scene.submarineLeave.frame -le 45
} 'fresh diver, oxygen, and moving submarine telemetry' -AllowEmptyOxygen:($Action -in 'Dive','Return')

$verifiedSwampRoute = $Action -eq 'Dive' -and $diveRoom -in 'rm_ocean_swamp_02','rm_ocean_swamp_03' -and
    $UseSubmarineBubble -and $nativeTerrain -and $nativeTerrain[$diveRoom]
$furtherSwampRoute = $verifiedSwampRoute -and $state.scene.player.oxygen_max -ge 45000
$deeperSwampRoute = $furtherSwampRoute -or ($verifiedSwampRoute -and $diveRoom -eq 'rm_ocean_swamp_02' -and
    $state.scene.player.oxygen_max -ge 16000)

switch ($Action) {
    'Return' {
        $returned = Return-ToIsland $state
        if ($returned.room -eq 'rm_main_island') { [IO.File]::Delete($returnCheckpoint) }
        if ($RequireLiveDiver) {
            $returned | Add-Member -NotePropertyName autoplayDive -NotePropertyValue ([pscustomobject]@{
                immediateReturn=$true; startingOxygen=$state.scene.player.oxygen
                oxygenAfterReturn=$returned.scene.player.oxygen; elapsedMs=$timer.ElapsedMilliseconds
            })
        }
        return $returned
    }
    'Move' { return Swim-To $state @{x = $X; y = $Y} 16 }
    'Target' {
        if ((Get-OxygenPercent $state) -le $ReturnOxygen) { throw 'Oxygen is at the return reserve.' }
        $target = if ($hasX) { @{x = $X; y = $Y} } else { Get-NearbyTarget $state $Kind }
        if (!$target) { throw "No $Kind target is visible within reach of the submarine route." }
        return Invoke-DiveTarget $state $target $Kind
    }
    'Dive' {
        if ($magmaExpedition) {
            if ($Kind -eq 'Jellyfish') {
                if ($dynamicMagma) { return Invoke-DynamicMagmaFishing $state }
                return Invoke-MagmaIIShelterFishing $state
            }
            if ($dynamicMagma) { return Invoke-DynamicMagmaResource $state }
            return Invoke-MagmaIIWestResource $state
        }
        if (!$magmaScout) { $state = Wait-ForSubmarineToSettle $state }
        if ($state.room -eq 'rm_main_island') { return $state }
        Write-Verbose "Dive ready at frame $($state.frame), oxygen $($state.scene.player.oxygen), tools $($state.scene.player.can_use_tool), targets $(@($state.targets.jellyfish).Count)/$(@($state.targets.resources).Count)."
        if ($state.room -eq 'rm_ocean_magma_01' -and $Kind -in 'Resource', 'Jellyfish') {
            return Invoke-MagmaWestProbe $state $Kind
        }
        $longRoute = $state.room -ne 'rm_ocean_shallows_01' -and $state.scene.player.oxygen_max -ge 400
        $harvestBudget = $HarvestSeconds + (2 * [int]$longRoute) + (6 * [int]$deeperSwampRoute)
        $harvestDeadline = $timer.Elapsed.TotalSeconds + $harvestBudget
        $fishDeadline = $harvestDeadline - 0.4 * $harvestBudget
        $shotLimit = [Math]::Max(10, ($HarvestSeconds * 2 - 2)) + (6 * [int]$longRoute) + (8 * [int]$deeperSwampRoute)
        $startingOxygen = [double]$state.scene.player.oxygen
        $minimumOxygen = $startingOxygen
        $maxDistanceFromSubmarine = 0.0
        $diveEndReason = 'harvest-budget'
        $safeSwampPosition = $null
        $avoidedSwampTarget = $null
        $target = $null
        $swampRouteCorrections = 0
        $shots = 0
        $fishShots = 0
        $oxygenBuffer = 8.0
        $lastAim = $null
        $recentCatch = $null
        $attemptsAtAim = 0
        $projectilesAtFirstAim = [long]$state.projectiles.bubble
        $trail = [Collections.Generic.List[object]]::new()
        $trail.Add($state.scene.player)
        $shootFromGlacialShaft = $Kind -eq 'Jellyfish' -and $state.room -eq 'rm_ocean_glacial_01'
        $isFirstSwampRoom = $state.room -eq 'rm_ocean_swamp_01'
        $isSecondSwampRoom = $state.room -eq 'rm_ocean_swamp_02'
        $isThirdSwampRoom = $state.room -eq 'rm_ocean_swamp_03'
        $adaptiveHarvestMovement = $isThirdSwampRoom -and $deeperSwampRoute
        $script:harvestPulseSpeed = 3.5
        $useBoundedSwampRoute = $isSecondSwampRoom -or $isThirdSwampRoom
        $isSwampRoom = $isFirstSwampRoom -or $useBoundedSwampRoute
        $initialKind = if ($mixed) { 'Jellyfish' } else { $Kind }
        $longShelfMining = $Kind -eq 'Resource' -and $shelfResourceRoom -and $nativeTerrain -and
            $nativeTerrain[$state.room] -and $PSBoundParameters.ContainsKey('MagmaPlasmaAimRange')
        $longShelfShots = 0
        $shelfPickupApproaches = 0
        $useFishStandOff = $initialKind -eq 'Jellyfish' -and ($state.room -like 'rm_ocean_glacial_*' -or $isSwampRoom)
        $scoutMargin = if ($useBoundedSwampRoute) { 18 } else { 14 }
        $scoutPulse = if ($isThirdSwampRoom) { 24 } else { 42 }
        $scoutPoints = @()
        if ($shootFromGlacialShaft -and $state.scene.player.oxygen_max -ge 1600) {
            $scoutPoints = @{x=224;y=336}, @{x=344;y=336}, @{x=480;y=352}
        }
        if ($isFirstSwampRoom) {
            $scoutPoints = @{x=216;y=304}, @{x=264;y=352}, @{x=344;y=352}, @{x=464;y=352}, @{x=565;y=352}
        } elseif ($isSecondSwampRoom) {
            $scoutPoints = @{x=272;y=220}, @{x=328;y=264}, @{x=384;y=304}
            if ($state.scene.player.oxygen_max -ge 16000) { $scoutPoints += @{x=416;y=275} }
            if ($deeperSwampRoute) {
                $scoutPoints += @{x=432;y=368}, @{x=480;y=448}
                if ($furtherSwampRoute) { $scoutPoints += @{x=480;y=500}, @{x=448;y=550}, @{x=416;y=600} }
                $scoutPoints += @{x=535;y=401}, @{x=528;y=330}
            }
        } elseif ($isThirdSwampRoom) {
            $scoutPoints = @{x=500;y=744}, @{x=443;y=801}, @{x=414;y=732}
            if ($furtherSwampRoute) {
                $scoutPoints = @{x=500;y=744}, @{x=552;y=752}, @{x=610;y=760}, @{x=672;y=754},
                    @{x=736;y=768}, @{x=784;y=772}, @{x=443;y=801}, @{x=468;y=868}, @{x=454;y=916}
            }
        }
        $scoutIndex = 0
        $approach = @()
        $lookout = $null
        if ($Kind -eq 'Resource' -and $state.room -eq 'rm_ocean_glacial_02' -and $state.scene.player.x -lt 300) {
            $approach = @{x=220;y=379}, @{x=500;y=379}
            if ($longShelfMining) { $approach = @{x=220;y=379}, @{x=390;y=379}, @{x=500;y=379} }
            $lookout = @{x=560;y=379}
        } elseif ($shootFromGlacialShaft -and $state.scene.player.y -lt 240) {
            $approach = @(@{x=224;y=247})
            $lookout = @{x=224;y=320}
        } elseif ($isFirstSwampRoom -and !(Get-NearbyTarget $state $initialKind) -and
            (!$mixed -or !(Get-NearbyTarget $state 'Resource'))) {
            $approach = @(@{x=216;y=336})
            $lookout = @{x=264;y=352}
        } elseif ($useFishStandOff -and !$shootFromGlacialShaft -and !$isSwampRoom -and !(Get-NearbyTarget $state $Kind)) {
            if ($state.room -eq 'rm_ocean_glacial_02') {
                $approach = @(@{x=220;y=379})
                $lookout = @{x=255;y=379}
            } else {
                $approach = @(@{x=520;y=200})
                $lookout = @{x=608;y=208}
            }
        }
        if ($approach.Count) {
            try {
                foreach ($point in $approach) {
                    if (($useFishStandOff -or $isFirstSwampRoom) -and
                        !(Test-OceanSegment $state.room $state.scene.player $point 14)) { break }
                    $state = Swim-To $state $point 15
                    $trail.Add($state.scene.player)
                    if ($longShelfMining) {
                        $shelfPlan = Get-LongShelfResourcePlan $state (Get-LiveSubmarine $state)
                        if ($shelfPlan -and $shelfPlan.distance -le $shelfPlan.range) { break }
                    }
                }
                if (!(Get-NearbyTarget $state $initialKind) -and
                    (!$mixed -or !(Get-NearbyTarget $state 'Resource')) -and
                    $timer.Elapsed.TotalSeconds -lt $harvestDeadline -and
                    ((!$useFishStandOff -and !$isFirstSwampRoom) -or
                        (Test-OceanSegment $state.room $state.scene.player $lookout 14))) {
                    $state = Swim-To $state $lookout 15
                    $trail.Add($state.scene.player)
                }
            } catch {
                if ($_.Exception.Message -notlike 'Could not swim toward*' -and
                    $_.Exception.Message -notlike 'Stopped moving away from the submarine*') { throw }
                $state = Read-DiveSnapshot
            }
        }
        while ($state.room -eq $diveRoom -and $shots -lt $shotLimit -and
               $state.scene.player.can_use_tool -ne 0 -and $timer.Elapsed.TotalSeconds -lt $harvestDeadline) {
            if ($script:diveFull) { $diveEndReason='native-pack-full'; break }
            $oxygenBefore = Get-OxygenPercent $state
            $minimumOxygen = [Math]::Min($minimumOxygen, [double]$state.scene.player.oxygen)
            $lowOnOxygen = $oxygenBefore -le ($ReturnOxygen + $oxygenBuffer)
            if ($deeperSwampRoute) {
                $liveAnchor = Get-LiveSubmarine $state
                $maxDistanceFromSubmarine = [Math]::Max($maxDistanceFromSubmarine, (Get-Distance $state.scene.player $liveAnchor))
                $returnRoute = Get-SwampSafeReturn $state.room $state.scene.player $liveAnchor
                if (!$returnRoute) {
                    if ($safeSwampPosition -and $swampRouteCorrections -lt 2 -and
                        $timer.Elapsed.TotalSeconds + 1.5 -lt $harvestDeadline -and
                        (Get-Distance $state.scene.player $safeSwampPosition) -le 85 -and
                        # The diver already occupies this position near a wall. Leave along the observed route.
                        (Test-OceanSegment $state.room $state.scene.player $safeSwampPosition 4)) {
                        $safeRoute = Get-SwampSafeReturn $state.room $safeSwampPosition $liveAnchor
                        if ($safeRoute -and $state.scene.player.oxygen -gt (Get-SwampReturnMinimum $state $safeRoute $liveAnchor 100)) {
                            ++$swampRouteCorrections
                            if ($isThirdSwampRoom -and $target) {
                                $avoidedSwampTarget = @{x=$target.x;y=$target.y;kind=$targetKind}
                            }
                            $state = Swim-Pulse $state $safeSwampPosition 36 2.5 -Returning -Adaptive:$adaptiveHarvestMovement
                            if ($lastAim) { $recentCatch = @{x=$lastAim.x;y=$lastAim.y;untilFrame=$state.frame + 150} }
                            continue
                        }
                    }
                    $diveEndReason = 'return-path'
                    break
                }
                $safeSwampPosition = $state.scene.player
                $lowOnOxygen = $state.scene.player.oxygen -le (Get-SwampReturnMinimum $state $returnRoute $liveAnchor 30)
            }
            if ($lowOnOxygen) {
                $diveEndReason = 'return-oxygen'
                $timeUntilReturn = $harvestDeadline - $timer.Elapsed.TotalSeconds
                if (!$UseSubmarineBubble -or $timeUntilReturn -lt 3.5) { break }
                $travelAnchor = Get-LiveSubmarine $state
                $state = Swim-BackToSubmarine $state $travelAnchor 55 $trail
                if ($state.room -eq 'rm_main_island' -or $state.scene.player.can_use_tool -eq 0) { break }
                if ($shots -gt 0) {
                    $state = Invoke-DiveCommand $state input @{frames=1; values=@{reload_tool=1}} 1
                }
                $needed = [Math]::Min(95, [Math]::Max(80, $ReturnOxygen + $oxygenBuffer + 8))
                try {
                    $state = Wait-DiveSnapshot {
                        param($sample)
                        $sample.scene.player.can_use_tool -eq 0 -or (Get-OxygenPercent $sample) -ge $needed
                    } 'the native submarine bubble to replenish oxygen' -MaxWaitSeconds 2.6
                } catch {
                    if ($_.Exception.Message -notlike 'Timed out waiting for the native submarine bubble*') { throw }
                    $state = Read-DiveSnapshot
                    break
                }
                if ($state.scene.player.can_use_tool -eq 0) { break }
                Write-Verbose "Native submarine bubble replenished oxygen to $($state.scene.player.oxygen)."
                $oxygenBuffer = 8
                $trail.Clear()
                $trail.Add($state.scene.player)
                $diveEndReason = 'harvest-budget'
                continue
            }
            $deprioritized = if ($initialKind -eq 'Jellyfish') {
                if ($isSwampRoom) {
                    if ($attemptsAtAim -ge 6 -and [long]$state.projectiles.bubble - $projectilesAtFirstAim -ge 12) { $lastAim }
                } elseif ($attemptsAtAim -ge 2) { $lastAim }
            }
            $targetKinds = if (!$mixed) { $Kind }
                elseif ($fishShots -ge 10 -or ($fishShots -gt 0 -and $timer.Elapsed.TotalSeconds -ge $fishDeadline)) { 'Resource', 'Jellyfish' }
                else { 'Jellyfish', 'Resource' }
            $shelfPlan = $null
            foreach ($targetKind in $targetKinds) {
                if ($longShelfMining) { $shelfPlan = Get-LongShelfResourcePlan $state (Get-LiveSubmarine $state) }
                $target = if ($shelfPlan) { $shelfPlan.target }
                elseif ($targetKind -eq 'Jellyfish') {
                    Get-NearbyTarget $state $targetKind $deprioritized $recentCatch
                } else {
                    Get-NearbyTarget $state $targetKind
                }
                if ($target) { break }
            }
            if (!$target) {
                $scout = $null
                while ($scoutIndex -lt $scoutPoints.Count -and
                    ($deeperSwampRoute -or $oxygenBefore -gt ($ReturnOxygen + 18))) {
                    $point = $scoutPoints[$scoutIndex]
                    ++$scoutIndex
                    if ($useBoundedSwampRoute) {
                        $anchor = Get-LiveSubmarine $state
                        $ring = if ($anchor.range -gt 0) { $anchor.range } else { 75 }
                        $scoutRadius = if ($furtherSwampRoute) { 475 }
                            elseif ($deeperSwampRoute) { 400 }
                            elseif ($isThirdSwampRoom) { [Math]::Max(16, $ring - 8) }
                            elseif ($state.scene.player.oxygen_max -ge 16000) { $ring + 188 } else { $ring + 120 }
                        $scoutDistance = Get-Distance $point $anchor
                        if ($scoutDistance -gt $scoutRadius) { continue }
                        $route = if ($furtherSwampRoute) { Get-SwampSafeReturn $state.room $point $anchor }
                            elseif (Test-OceanSegment $state.room $point $anchor $scoutMargin) { @{distance=$scoutDistance} }
                        if (!$route -or ($deeperSwampRoute -and
                            $state.scene.player.oxygen -le (Get-SwampReturnMinimum $state $route $anchor 60))) { continue }
                    }
                    if ((Get-Distance $state.scene.player $point) -gt 20 -and
                        (Test-OceanSegment $state.room $state.scene.player $point $scoutMargin)) {
                        $scout = $point
                        break
                    }
                }
                if ($scout) {
                    $distanceBeforeScout = Get-Distance $state.scene.player $scout
                    $state = Swim-Pulse $state $scout $scoutPulse 2.5 -Adaptive:$adaptiveHarvestMovement
                    $trail.Add($state.scene.player)
                    $distanceAfterScout = Get-Distance $state.scene.player $scout
                    if ($distanceAfterScout -gt 24 -and $distanceBeforeScout - $distanceAfterScout -ge 3) { --$scoutIndex }
                    continue
                }
                $diveEndReason = 'no-reachable-target'
                Write-Verbose "No $Kind target within the submarine route at frame $($state.frame)."
                break
            }
            $fishStandOffForTarget = $useFishStandOff -and $targetKind -eq 'Jellyfish'
            $targetRange = if ($shelfPlan) { $shelfPlan.range }
                elseif ($targetKind -eq 'Resource' -and $isSwampRoom) { 62 }
                elseif ($targetKind -eq 'Resource') { 38 } elseif ($fishStandOffForTarget) { 82 } else { 32 }
            $targetDistance = Get-Distance $state.scene.player $target
            if ($fishStandOffForTarget -and $targetDistance -gt 1 -and
                ($targetDistance -lt 48 -or $targetDistance -gt $targetRange)) {
                $motionTarget = Get-StandOffPoint $state.scene.player $target $targetDistance
                $state = Swim-Pulse $state $motionTarget 24 2.5 -Adaptive:$adaptiveHarvestMovement
            } elseif ($targetDistance -gt $targetRange) {
                $motionTarget = if ($shelfPlan) { $shelfPlan.fireAt }
                elseif ($isSwampRoom -and $targetKind -eq 'Resource') {
                    Get-StandOffPoint $state.scene.player $target $targetDistance 54
                } else { $target }
                $state = Swim-Pulse $state $motionTarget 24 2.5 -Adaptive:$adaptiveHarvestMovement
            } else {
                $caughtBefore = [int]$state.inventories.player.jellyfish
                $projectilesBefore = [long]$state.projectiles.bubble
                $plasmaBefore = [long]$state.projectiles.plasma
                $state = Invoke-DiveTarget $state $target $targetKind
                ++$shots
                if ($shelfPlan -and $shelfPlan.collectionDistance -gt 8 -and [long]$state.projectiles.plasma -gt $plasmaBefore) {
                    ++$longShelfShots
                    $margin = if ($isThirdSwampRoom) { 18 } else { 14 }
                    if ($state.room -eq $diveRoom -and $state.scene.player.can_use_tool -eq 1 -and
                        (Get-OxygenPercent $state) -gt $ReturnOxygen -and
                        (Test-OceanSegment $state.room $state.scene.player $shelfPlan.pickup $margin)) {
                        try {
                            $state = Swim-To $state $shelfPlan.pickup 8
                            $trail.Add($state.scene.player)
                            ++$shelfPickupApproaches
                        } catch {
                            if ($_.Exception.Message -notlike 'Could not swim toward*' -and
                                $_.Exception.Message -notlike 'Stopped moving away from the submarine*') { throw }
                            $state = Read-DiveSnapshot
                            $diveEndReason = 'shelf-pickup-route'
                            break
                        }
                    }
                }
                if ($targetKind -eq 'Jellyfish') {
                    ++$fishShots
                    if ($fishStandOffForTarget -and [int]$state.inventories.player.jellyfish -gt $caughtBefore) {
                        $recentCatch = @{x=$target.x;y=$target.y;untilFrame=($state.frame + 90)}
                        Write-Verbose "Native backpack holds $($state.inventories.player.jellyfish) jellyfish."
                    }
                    if ($lastAim -and (Get-Distance $target $lastAim) -lt 32) { ++$attemptsAtAim }
                    else {
                        $attemptsAtAim = 1
                        $projectilesAtFirstAim = $projectilesBefore
                    }
                    $lastAim = $target
                }
                Write-Verbose "Sent $targetKind aim and fire at ($($target.x), $($target.y)); oxygen $($state.scene.player.oxygen), bubble $($state.projectiles.bubble), plasma $($state.projectiles.plasma)."
            }
            if ((Get-Distance $state.scene.player $trail[$trail.Count - 1]) -ge 16) {
                $trail.Add($state.scene.player)
            }
            $oxygenUsed = $oxygenBefore - (Get-OxygenPercent $state)
            $oxygenBuffer = [Math]::Max($oxygenBuffer, 1.25 * $oxygenUsed)
        }
        $oxygenBeforeReturn = [double]$state.scene.player.oxygen
        $diveExitPoint = if ($state.room -eq $diveRoom) { @{x=$state.scene.player.x; y=$state.scene.player.y} }
        $minimumOxygen = [Math]::Min($minimumOxygen, $oxygenBeforeReturn)
        $returned = Return-ToIsland $state $trail
        if ($returned.room -eq 'rm_main_island') { [IO.File]::Delete($returnCheckpoint) }
        $returned | Add-Member -NotePropertyName autoplayDive -NotePropertyValue ([pscustomobject]@{
            deeperSwampRoute=[bool]$deeperSwampRoute; furtherSwampRoute=[bool]$furtherSwampRoute
            reason=$diveEndReason; packFull=$script:diveFull; shots=$shots; harvestBudgetSeconds=$harvestBudget
            routeCorrections=$swampRouteCorrections
            adjustedSwimPixelsPerFrame=if ($adaptiveHarvestMovement) { $script:harvestPulseSpeed }
            startingOxygen=$startingOxygen; minimumHarvestOxygen=$minimumOxygen
            oxygenBeforeReturn=$oxygenBeforeReturn; oxygenAfterReturn=$returned.scene.player.oxygen; exitPoint=$diveExitPoint
            maxDistanceFromSubmarine=[Math]::Round($maxDistanceFromSubmarine, 1)
            shelfResourceAimRange=if ($longShelfMining) { $MagmaPlasmaAimRange }
            shelfResourceShots=if ($longShelfMining) { $longShelfShots }
            shelfPickupApproaches=if ($longShelfMining) { $shelfPickupApproaches }
            elapsedMs=$timer.ElapsedMilliseconds
        })
        return $returned
    }
}
