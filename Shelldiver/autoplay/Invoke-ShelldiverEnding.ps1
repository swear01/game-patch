#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(30, 180)] [int]$TimeoutSeconds = 90,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json')
)

$ErrorActionPreference = 'Stop'
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$island = Join-Path $PSScriptRoot 'Invoke-ShelldiverIsland.ps1'
$upgrade = Join-Path $PSScriptRoot 'Invoke-ShelldiverUpgrade.ps1'
$clock = [Diagnostics.Stopwatch]::StartNew()
$finalPrice = 10000000000000000L
$gamePid = $null

function Read-EndingSave {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    try {
        $stream = [IO.File]::Open($SavePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
        $reader = [IO.StreamReader]::new($stream)
        try { $encoded = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        if (!$encoded.StartsWith('{')) {
            $raw = [Convert]::FromHexString($encoded)
            if ($raw.Length -lt 16) { return }
            $length = [BitConverter]::ToInt32($raw, 12)
            if ($length -le 0 -or $length -gt $raw.Length - 16) { return }
            $encoded = [Text.Encoding]::UTF8.GetString($raw,16,$length)
        }
        $save = ConvertFrom-Json -InputObject $encoded -AsHashtable
        if ($save.global) { $save = $save.global }
        if ($save.skills_saved) { return $save }
    } catch [IO.IOException], [FormatException], [System.ArgumentException] {
        return
    }
}

function Get-EndingSnapshot {
    $sample = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds 3
    if ($gamePid -and $sample.pid -ne $gamePid) { throw 'Shelldiver restarted before ending verification.' }
    return $sample
}

function Wait-EndingProgress([scriptblock]$Condition, [double]$Seconds) {
    $deadline = [Math]::Min($clock.Elapsed.TotalSeconds + $Seconds, $TimeoutSeconds)
    do {
        $sample = Get-EndingSnapshot
        $saved = Read-EndingSave
        if ($saved -and (& $Condition $sample $saved)) {
            return [pscustomobject]@{ state=$sample; save=$saved }
        }
        Start-Sleep -Milliseconds 100
    } while ($clock.Elapsed.TotalSeconds -lt $deadline)
}

$saved = Read-EndingSave
if (!$saved) { throw 'The original Shelldiver save is unavailable.' }
$ranks = [int]($saved.skills_saved.Values | Measure-Object -Sum).Sum
$hammockRank = [int]$saved.skills_saved.o_skill_hammock
if ($saved.has_played_hammock_cutscene -and $hammockRank -gt 0) {
    $live = Get-EndingSnapshot
    if ($live.flags.has_played_hammock_cutscene -and !$live.flags.in_cutscene -and !$live.flags.is_on_final_cutscene) {
        return [pscustomobject]@{phase='verified'; pid=$live.pid; room=$live.room; ranks=$ranks; endingSaved=$true; elapsedMs=$clock.ElapsedMilliseconds}
    }
}
$missingFinalSkills = @(
    'o_skill_crystal_final', 'o_skill_obsidian_final', 'o_skill_scrap_final',
    'o_skill_flask_final', 'o_skill_mushroom_final'
) | Where-Object { [int]$saved.skills_saved[$_] -lt 1 }
if (!$hammockRank -and ($missingFinalSkills -or $saved.shell_coins -lt $finalPrice)) {
    return [pscustomobject]@{
        phase='locked'; ranks=$ranks; shells=$saved.shell_coins; missingFinalSkills=@($missingFinalSkills)
        requiredShells=$finalPrice; elapsedMs=$clock.ElapsedMilliseconds
    }
}

$state = Get-EndingSnapshot
$gamePid = $state.pid
if (!$gamePid -or $state.room -ne 'rm_main_island' -or $state.flags.transitioning) {
    throw 'Start the native ending route from the resident island.'
}
if (!$hammockRank) {
    $purchase = & $upgrade -Skill o_skill_hammock -Mailbox $Mailbox -SavePath $SavePath -TimeoutSeconds 25
    $receipt = $purchase.purchases[0]
    if ($purchase.pid -ne $gamePid -or !$receipt.purchased -or $receipt.after -ne 1 -or $receipt.spent.shells -ne $finalPrice) {
        throw 'The native final upgrade could not be verified.'
    }
}

$ready = Wait-EndingProgress {
    param($sample, $original)
    $sample.room -eq 'rm_main_island' -and !$sample.flags.transitioning -and $sample.activeInputFrames -eq 0 -and
        $sample.scene.player.can_use_tool -eq 1 -and $null -ne $sample.scene.hammock.x -and
        [int]$original.skills_saved.o_skill_hammock -gt 0
} 15
if (!$ready) { throw 'The native island did not become ready after the final upgrade.' }
$state = & $island -Action Move -X $ready.state.scene.hammock.x -Tolerance 10 -Mailbox $Mailbox -TimeoutSeconds 12
if ($state.pid -ne $gamePid) { throw 'Shelldiver restarted while approaching the hammock.' }
$interaction = '{"frames":1,"values":{"interact":1,"interact_hold":true}}'
$null = & $control -Action input -ParametersJson $interaction -Mailbox $Mailbox

$first = Wait-EndingProgress {
    param($sample, $original)
    $original.has_played_hammock_cutscene -or ($sample.scene.player.can_use_tool -eq 0 -and
        $sample.activeInputFrames -eq 0)
} 5
if (!$first -or (!$first.save.has_played_hammock_cutscene -and !$first.state.flags.is_on_final_cutscene)) {
    $settled = Wait-EndingProgress {
        param($sample, $original)
        $original.has_played_hammock_cutscene -or $sample.flags.is_on_final_cutscene -or ($sample.room -eq 'rm_main_island' -and
            !$sample.flags.transitioning -and $sample.scene.player.can_use_tool -eq 1 -and
            [Math]::Abs($sample.scene.hammock.x - $sample.scene.player.x) -le 20)
    } 15
    if (!$settled) { throw 'The native hammock interaction did not settle.' }
    if (!$settled.save.has_played_hammock_cutscene -and !$settled.state.flags.is_on_final_cutscene) {
        $null = & $control -Action input -ParametersJson $interaction -Mailbox $Mailbox
    }
}

$ending = Wait-EndingProgress {
    param($sample, $original)
    $original.has_played_hammock_cutscene -and $sample.flags.has_played_hammock_cutscene -and
        !$sample.flags.in_cutscene -and !$sample.flags.is_on_final_cutscene -and !$sample.flags.transitioning -and
        ($sample.room -ne 'rm_main_island' -or $sample.scene.player.can_use_tool -eq 1) -and
        [int]$original.skills_saved.o_skill_hammock -eq 1
} $TimeoutSeconds
if (!$ending) { throw 'The native hammock ending did not appear in both telemetry and the original save.' }
[pscustomobject]@{
    phase = 'verified'
    pid = $gamePid
    ranks = [int]($ending.save.skills_saved.Values | Measure-Object -Sum).Sum
    endingSaved = $true
    room = $ending.state.room
    elapsedMs = $clock.ElapsedMilliseconds
}
