#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?:[A-Za-z][A-Za-z0-9]*|o_skill_[a-z0-9_]+)$')]
    [string[]] $Skill,
    [ValidateRange(-120, 120)] [int] $PanXFrames,
    [ValidateRange(-120, 120)] [int] $PanYFrames,
    [ValidateRange(0, 3072)] [int] $CameraCenterX = 1536,
    [ValidateRange(0, 3072)] [int] $CameraCenterY,
    [ValidateRange(8, 90)] [int] $TimeoutSeconds = 20,
    [string] $Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string] $SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json'),
    [switch]$KeepCameraPosition
)

$ErrorActionPreference = 'Stop'
$walletFields = @{
    shells='shell_coins'; scrap='scrap_coins'; crystals='crystal_coins'
    mushrooms='mushroom_coins'; obsidian='obsidian_coins'; lifeVials='flask_coins'
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$island = Join-Path $PSScriptRoot 'Invoke-ShelldiverIsland.ps1'
$aliases = @{
    JellyfishValue='o_skill_jellyfish_value_01'; DeepBreath='o_skill_deep_breath'
    OxygenTank='o_skill_oxygen_tank_01'; LightFeet='o_skill_movement_speed_01'
    BubbleDamage='o_skill_bubble_damage_01'; PlasmaDamage='o_skill_plasma_damage_01'
    PlasmaCharge='o_skill_plasma_charge_01'; PlasmaRange='o_skill_plasma_range_01'
    PlasmaTank='o_skill_plasma_tank_01'; BubbleSize='o_skill_bubble_size_01'
    BubbleTank='o_skill_bubble_tank_01'; BubbleDoppel='o_skill_bubble_doppel_01'
    JellyfishInsurance='o_skill_jellyfish_insurance_01'; ScrapValue='o_skill_scrap_value'
    Biodiversity='o_skill_biodiversity_shallows'; Capacity='o_skill_slot_capacity_01'
    Slots='o_skill_player_slots_01'
}
$cameraReader = Join-Path $PSScriptRoot 'Get-ShelldiverSkillCamera.ps1'
$manualPan = $PSBoundParameters.ContainsKey('PanXFrames') -or $PSBoundParameters.ContainsKey('PanYFrames')
$manualX = $PSBoundParameters.ContainsKey('CameraCenterX')
$manualY = $PSBoundParameters.ContainsKey('CameraCenterY')
$route = @{ panned = $false; pixelsPerFrame = @{ X=5.0; Y=5.0 } }

if (![IO.File]::Exists($cameraReader)) { throw 'The read-only native skill camera helper is required.' }
$stockLayout = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'skill-layout.original.json') | ConvertFrom-Json -AsHashtable
if ($stockLayout.room -ne 'rm_skill_tree' -or $stockLayout.nodeCount -ne 241) {
    throw 'Unexpected stock skill layout.'
}
$locations = @{}
foreach ($name in ($Skill | Select-Object -Unique)) {
    $id = if ($aliases.ContainsKey($name)) { $aliases[$name] } else { $name }
    $node = $stockLayout.nodes[$id]
    if (!$node -or $null -eq $node.x -or $null -eq $node.y) {
        throw "The stock layout has no node '$name'."
    }
    $locations[$name] = @{ id=$id; x=[double]$node.x; y=[double]$node.y }
}

$initial = & $control -Action snapshot -Mailbox $Mailbox
if ($initial.room -ne 'rm_main_island' -or $initial.flags.transitioning -or
    $initial.scene.player.can_use_tool -eq 0 -or $null -eq $initial.scene.upgradeArea.x) {
    throw 'Start on the settled island outside a game menu.'
}

function Read-SkillSave {
    try {
        $raw = [Convert]::FromHexString([IO.File]::ReadAllText($SavePath).Trim())
        return [Text.Encoding]::UTF8.GetString($raw, 16, $raw.Length-16).TrimEnd([char]0) | ConvertFrom-Json -AsHashtable
    } catch [IO.IOException], [FormatException] {
        return $null
    }
}

function Wait-SkillSave {
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $result = Read-SkillSave
        if ($result -and $result.skills_saved) { return $result }
        Start-Sleep -Milliseconds 40
    }
    throw 'The native skill save could not be read.'
}

function Invoke-SkillPan([int]$Frames, [string]$Negative, [string]$Positive) {
    if ($Frames -eq 0) { return }
    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'The upgrade time limit expired.' }
    $route.panned = $true
    $count = [Math]::Abs($Frames)
    $direction = if ($Frames -lt 0) { $Negative } else { $Positive }
    $payload = @{frames=$count; values=@{$direction=1}} | ConvertTo-Json -Depth 4 -Compress
    $ack = & $control -Action input -ParametersJson $payload -Mailbox $Mailbox
    if ($null -eq $ack.frame) { throw 'The native skill camera did not acknowledge its input frame.' }
    $deadline = [Math]::Min($clock.Elapsed.TotalSeconds + 2.5 + ($count + 28) / 55.0, $TimeoutSeconds)
    do {
        $state = Read-SkillPanel
        if ($state.activeInputFrames -eq 0 -and $state.frame -ge $ack.frame + $count + 28) { return }
        Start-Sleep -Milliseconds 25
    } until ($clock.Elapsed.TotalSeconds -ge $deadline)
    throw 'The native skill camera did not settle.'
}

function Read-SkillPanel {
    $state = & $control -Action snapshot -Mailbox $Mailbox
    if ($state.pid -ne $initial.pid -or $state.room -ne 'rm_main_island' -or
        $state.scene.player.can_use_tool -ne 0 -or $state.flags.transitioning -or $state.flags.in_cutscene) {
        throw 'The resident skill panel is no longer available.'
    }
    return $state
}

function Read-LiveSkillCamera {
    $deadline = [Math]::Min($clock.Elapsed.TotalSeconds + 2.0, $TimeoutSeconds)
    do {
        $state = Read-SkillPanel
        if ($state.activeInputFrames -eq 0) {
            try {
                $camera = & $cameraReader -Mailbox $Mailbox -ExpectedPid $initial.pid
                if (!$camera -or $camera.pid -ne $initial.pid -or
                    $null -eq $camera.centerX -or $null -eq $camera.centerY -or $camera.zoom -ne 1.0) {
                    throw 'The read-only helper did not confirm a stock-zoom skill camera.'
                }
                return $camera
            } catch {
                if ($_.Exception.Message -notlike '*still moving or shaking*') { throw }
            }
        }
        Start-Sleep -Milliseconds 25
    } until ($clock.Elapsed.TotalSeconds -ge $deadline)
    throw 'The native skill camera did not become stationary.'
}

function Get-SkillPoint($Node, $Camera) {
    return @{
        x = .5 + ($Node.x - $Camera.centerX) * $Camera.zoom / 640.0
        y = .5 + ($Node.y - $Camera.centerY) * $Camera.zoom / 360.0
    }
}

function Move-SkillCamera($Camera, [double]$X, [double]$Y, [double]$ToleranceX, [double]$ToleranceY, [int]$MaxPulses) {
    $stalled = @{ X=0; Y=0 }
    for ($pulse = 0; $pulse -lt $MaxPulses; ++$pulse) {
        $dx = $X - $Camera.centerX
        $dy = $Y - $Camera.centerY
        if ([Math]::Abs($dx) -le $ToleranceX -and [Math]::Abs($dy) -le $ToleranceY) { return $Camera }

        if ([Math]::Abs($dx) -gt $ToleranceX) {
            $axis = 'X'
            $delta = $dx
            $from = $Camera.centerX
            $negative = 'left'
            $positive = 'right'
        } else {
            $axis = 'Y'
            $delta = $dy
            $from = $Camera.centerY
            $negative = 'up'
            $positive = 'down'
        }
        $direction = [Math]::Sign($delta)
        $count = [int][Math]::Clamp([Math]::Round([Math]::Abs($delta) / $route.pixelsPerFrame[$axis]), 1, 120)
        Invoke-SkillPan ($direction * $count) $negative $positive
        $Camera = Read-LiveSkillCamera
        $actual = if ($axis -eq 'X') { $Camera.centerX } else { $Camera.centerY }
        $progress = ($actual - $from) * $direction
        if ($progress -lt 1) {
            ++$stalled[$axis]
            if ($stalled[$axis] -ge 2) { break }
        } else {
            $stalled[$axis] = 0
            $route.pixelsPerFrame[$axis] = [Math]::Clamp($progress / $count, 0.5, 30.0)
        }
    }
    if ([Math]::Abs($X - $Camera.centerX) -le $ToleranceX -and
        [Math]::Abs($Y - $Camera.centerY) -le $ToleranceY) {
        return $Camera
    }
    throw "Could not reach the requested skill view around ($X, $Y). Last camera position was ($($Camera.centerX), $($Camera.centerY))."
}

$null = Wait-SkillSave
$null = & $island -Action Move -X $initial.scene.upgradeArea.x -Tolerance 12 -TimeoutSeconds ([math]::Min(12,$TimeoutSeconds)) -Mailbox $Mailbox
$openAck = & $control -Action input -ParametersJson '{"frames":1,"values":{"interact":1,"open_skilltree":1}}' -Mailbox $Mailbox
if ($null -eq $openAck.frame) { throw 'The skill panel input did not acknowledge its frame.' }

$opened = $false
$exitAck = $null
$originalCamera = $null
$receipts = [Collections.Generic.List[object]]::new()
try {
    $deadline = [math]::Min($clock.Elapsed.TotalSeconds + 2.5, $TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 45
        $state = & $control -Action snapshot -Mailbox $Mailbox
        if ($state.pid -ne $initial.pid -or $state.room -ne 'rm_main_island') { throw 'The resident island changed.' }
        $opened = $state.scene.player.can_use_tool -eq 0
        $ready = $opened -and !$state.flags.transitioning -and $state.frame -ge $openAck.frame + 40
    } until ($ready -or $clock.Elapsed.TotalSeconds -ge $deadline)
    if (!$ready) { throw 'The native upgrade panel did not open and settle.' }
    $originalCamera = Read-LiveSkillCamera
    if (($manualX -and [Math]::Abs($CameraCenterX - $originalCamera.centerX) -gt 1) -or
        ($manualY -and [Math]::Abs($CameraCenterY - $originalCamera.centerY) -gt 1)) {
        throw "The explicit camera center differs from the live skill view at ($($originalCamera.centerX), $($originalCamera.centerY))."
    }
    $camera = $originalCamera
    if ($PanXFrames) {
        Invoke-SkillPan $PanXFrames 'left' 'right'
        $camera = Read-LiveSkillCamera
    }
    if ($PanYFrames) {
        Invoke-SkillPan $PanYFrames 'up' 'down'
        $camera = Read-LiveSkillCamera
    }

    $lastTarget = $null
    foreach ($name in $Skill) {
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'The upgrade time limit expired.' }
        $node = $locations[$name]
        if ($node.id -ne $lastTarget) {
            if ($lastTarget) { $camera = Read-LiveSkillCamera }
            $point = Get-SkillPoint $node $camera
            $outside = $point.x -lt .05 -or $point.x -gt .95 -or $point.y -lt .08 -or $point.y -gt .92
            if ($outside -and !$manualPan) {
                $camera = Move-SkillCamera $camera $node.x $node.y (280.0 / $camera.zoom) (145.0 / $camera.zoom) 16
                $point = Get-SkillPoint $node $camera
            }
            if ($point.x -lt .05 -or $point.x -gt .95 -or $point.y -lt .08 -or $point.y -gt .92) {
                throw "The '$name' node is outside the verified live skill viewport."
            }
            $lastTarget = $node.id
        }
        $syncDeadline = [math]::Min($clock.Elapsed.TotalSeconds + 6, $TimeoutSeconds)
        do {
            $before = Wait-SkillSave
            $liveBefore = & $control -Action snapshot -Mailbox $Mailbox
            $savedLevels = ($before.skills_saved.Values | Measure-Object -Sum).Sum
            $liveLevels = $liveBefore.numbers.total_skill_levels_upgraded
            if ($null -eq $liveLevels -or $liveLevels -eq $savedLevels) { break }
            Start-Sleep -Milliseconds 60
        } while ($clock.Elapsed.TotalSeconds -lt $syncDeadline)
        if ($null -ne $liveLevels -and $liveLevels -ne $savedLevels) { throw 'The native skill tree and saved ranks have not synchronized.' }
        $rank = [int]$before.skills_saved[$node.id]
        $params = @{ x=$point.x; y=$point.y; button=1; holdFrames=1 } | ConvertTo-Json -Compress
        for ($attempt = 0; $attempt -lt 2; ++$attempt) {
            $null = & $control -Action click -ParametersJson $params -Mailbox $Mailbox
            $deadline = [math]::Min($clock.Elapsed.TotalSeconds + 1.2, $TimeoutSeconds)
            do {
                Start-Sleep -Milliseconds 45
                $after = Read-SkillSave
                if ($after) { $newRank = [int]$after.skills_saved[$node.id] }
            } until (($after -and $newRank -ne $rank) -or $clock.Elapsed.TotalSeconds -ge $deadline)
            if ($attempt -eq 0 -and $after -and $newRank -eq $rank) {
                $liveAfter = & $control -Action snapshot -Mailbox $Mailbox
                if ($null -ne $liveLevels -and $liveAfter.numbers.total_skill_levels_upgraded -gt $liveLevels) {
                    $deadline = [math]::Min($clock.Elapsed.TotalSeconds + 6, $TimeoutSeconds)
                    do {
                        Start-Sleep -Milliseconds 55
                        $after = Read-SkillSave
                        if ($after) { $newRank = [int]$after.skills_saved[$node.id] }
                    } until (($after -and $newRank -ne $rank) -or $clock.Elapsed.TotalSeconds -ge $deadline)
                    if ($newRank -eq $rank) { throw 'The native purchase was accepted and is awaiting its save.' }
                }
            }
            if (!$after) { throw 'No native save after the upgrade interaction.' }
            $changes = @($after.skills_saved.Keys | Where-Object { [int]$after.skills_saved[$_] -ne [int]$before.skills_saved[$_] })
            if ($changes.Count -gt 1 -or ($changes.Count -eq 1 -and $changes[0] -ne $node.id) -or $newRank -gt $rank + 1) {
                throw "Unexpected native skill changes while trying to buy $name. Native save records $($changes -join ', ')."
            }
            if ($newRank -eq $rank + 1) { break }
            if ($walletFields.Values | Where-Object { $after[$_] -ne $before[$_] }) {
                throw "The native currency changed without purchasing $name."
            }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'The upgrade time limit expired.' }
        }
        $spent = @{}
        foreach ($currency in $walletFields.Keys) {
            $field = $walletFields[$currency]
            $spent[$currency] = [double]$before[$field] - [double]$after[$field]
        }
        $receipts.Add([pscustomobject]@{
            skill=$name; before=$rank; after=$newRank; purchased=($newRank -gt $rank); spent=$spent
            shellsSpent=([double]$before.shell_coins-[double]$after.shell_coins)
            scrapSpent=([double]$before.scrap_coins-[double]$after.scrap_coins)
        })
    }
} finally {
    if ($opened) {
        $exitState = & $control -Action snapshot -Mailbox $Mailbox
        if ($exitState.pid -eq $initial.pid -and $exitState.room -eq 'rm_main_island' -and
            $exitState.scene.player.can_use_tool -eq 0 -and !$exitState.flags.transitioning -and
            !$exitState.flags.in_cutscene) {
            try {
                if (!$KeepCameraPosition -and $originalCamera -and $route.panned -and $clock.Elapsed.TotalSeconds + 2 -lt $TimeoutSeconds -and
                    'o_skill_hammock' -notin $Skill) {
                    $camera = Read-LiveSkillCamera
                    $null = Move-SkillCamera $camera $originalCamera.centerX $originalCamera.centerY 8 8 6
                }
            } catch {
                Write-Verbose "Could not restore the previous skill camera. $($_.Exception.Message)"
            } finally {
                $exitState = & $control -Action snapshot -Mailbox $Mailbox
                if ($exitState.pid -eq $initial.pid -and $exitState.room -eq 'rm_main_island' -and
                    $exitState.scene.player.can_use_tool -eq 0 -and !$exitState.flags.transitioning -and
                    !$exitState.flags.in_cutscene) {
                    $exitAck = & $control -Action input -ParametersJson '{"frames":1,"values":{"back":1,"ui_back":true}}' -Mailbox $Mailbox
                }
            }
        }
    }
}
if ($exitAck -and 'o_skill_hammock' -notin $Skill) {
    $deadline = $clock.Elapsed.TotalSeconds + 10
    do {
        $state = & $control -Action snapshot -Mailbox $Mailbox
        if ($state.pid -ne $initial.pid -or $state.room -ne 'rm_main_island') {
            throw 'The resident game moved out of the island after the skill panel closed.'
        }
        $settled = $state.frame -ge $exitAck.frame + 30 -and $state.scene.player.can_use_tool -eq 1 -and
            !$state.flags.transitioning -and !$state.flags.pause -and $state.activeInputFrames -eq 0
        if (!$settled) { Start-Sleep -Milliseconds 40 }
    } until ($settled -or $clock.Elapsed.TotalSeconds -ge $deadline)
    if (!$settled) { throw 'The native island did not become ready after the saved skill purchase.' }
}
[pscustomobject]@{pid=$initial.pid; elapsedMs=$clock.ElapsedMilliseconds; purchases=$receipts}
