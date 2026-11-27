#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('ExportCatalog','VerifyCompletion')]
    [string]$Action = 'VerifyCompletion',
    [ValidateRange(1,2147483647)] [int]$ExpectedPid,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json'),
    [string]$CatalogPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'native-skill-catalog-max800.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ShelldiverIdentity.ps1')
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'

function Read-VerificationSnapshot {
    $snapshot = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds 4
    $written = [DateTimeOffset]$snapshot.writtenUtc
    $age = ([DateTimeOffset]::UtcNow-$written).TotalSeconds
    if (!$snapshot.pid -or ($ExpectedPid -and $snapshot.pid -ne $ExpectedPid) -or
        !$snapshot.flags.files_loaded -or !$snapshot.inputReady -or $age -lt -1 -or $age -gt 4 -or
        $snapshot.flags.transitioning -or $snapshot.flags.in_cutscene -or $snapshot.flags.is_on_final_cutscene -or
        $snapshot.guiPointer.active -or $snapshot.activeInputFrames -ne 0) {
        throw 'A fresh settled Shelldiver snapshot is required.'
    }
    return $snapshot
}

function Export-StockSkillTable($Catalog) {
    $nodes = [ordered]@{}
    foreach ($name in $Catalog.nodes.Keys) {
        $node = $Catalog.nodes[$name]
        if ($node.maxRank -le 0 -or $node.prices.Count -ne $node.maxRank -or
            $null -eq $node.currency -or $node.prices -contains $null) {
            throw "The original price table is incomplete for $name."
        }
        $nodes[$name] = [ordered]@{
            maxRank=$node.maxRank; currency=$node.currency; prices=$node.prices
            needsAnyLevel=@($node.needsAnyLevel); needsMaxLevel=@($node.needsMaxLevel)
            rank=0; unlocked=$false
        }
    }
    if (($nodes.Values.maxRank | Measure-Object -Sum).Sum -ne 800) {
        throw 'The original skill table did not sum to 800 maximum ranks.'
    }
    return [ordered]@{
        allSkillsKind='array'; all_skill_levels=800; nodes=$nodes; positionCount=0
        prestige_level=0; room='rm_main_island'; total_skill_levels_upgraded=0; truncated=$false
    }
}

function Read-StockEndingSave {
    $data = [IO.File]::ReadAllText($SavePath).Trim()
    if (!$data.StartsWith('{')) {
        $buffer = [Convert]::FromHexString($data)
        if ($buffer.Length -lt 16) { throw 'The original save header is incomplete.' }
        $length = [BitConverter]::ToInt32($buffer,12)
        if ($length -le 0 -or $length -gt $buffer.Length - 16) { throw 'The original save length is invalid.' }
        $data = [Text.Encoding]::UTF8.GetString($buffer,16,$length)
    }
    $decoded = ConvertFrom-Json -InputObject $data -AsHashtable
    if ($decoded.global) { return $decoded.global }
    return $decoded
}

function Confirm-StockCompletion($Catalog, $Saved, $Live) {
    if (!$Saved.skills_saved -or $Catalog.total_skill_levels_upgraded -ne 800 -or
        $Live.numbers.total_skill_levels_upgraded -ne 800 -or
        !$Live.flags.has_played_hammock_cutscene -or !$Saved.has_played_hammock_cutscene -or
        $Saved.skills_saved.o_skill_hammock -ne 1 -or
        ($Saved.skills_saved.Values | Measure-Object -Sum).Sum -ne 800) {
        throw 'The original 800 ranks and completed hammock cutscene were not both verified.'
    }
    foreach ($currency in 'scrap','crystal','obsidian','mushroom','flask') {
        if ($Saved.skills_saved["o_skill_${currency}_final"] -ne 1) {
            throw "The original $currency branch is incomplete."
        }
    }
    foreach ($name in $Catalog.nodes.Keys) {
        $native = $Catalog.nodes[$name]
        if ($native.maxRank -le 0 -or $native.rank -ne $native.maxRank -or
            [int]$Saved.skills_saved[$name] -ne $native.rank) {
            throw "The live native maximum and saved rank differ for $name."
        }
    }
    [pscustomobject]@{phase='verified';room=$Live.room;ranks=800;nodesAtMaximum=241;endingSaved=$true}
}

$initial = Read-VerificationSnapshot
if (($Action -eq 'ExportCatalog' -and $initial.room -ne 'rm_main_island') -or
    ($Action -eq 'VerifyCompletion' -and $initial.room -notin 'rm_main_island','rm_main_menu')) {
    throw 'The native room does not support this verification. For export, load the settled island.'
}
$process = Get-Process -Id $initial.pid
try {
    Assert-ShelldiverIdentity $process
    $start = $process.StartTime
    $response = & $control -Action skills -Mailbox $Mailbox -TimeoutSeconds 5
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        $sample = Read-VerificationSnapshot
        if ($sample.pid -ne $initial.pid -or $sample.room -ne $initial.room -or $sample.frame -ge $response.frame) { break }
        Start-Sleep -Milliseconds 25
    } while ($wait.Elapsed.TotalSeconds -lt 2)
    $catalog = $response.data | ConvertTo-Json -Depth 13 -Compress | ConvertFrom-Json -AsHashtable
    if ($sample.pid -ne $initial.pid -or $sample.room -ne $initial.room -or $sample.frame -lt $response.frame -or
        $process.HasExited -or $process.StartTime -ne $start -or $catalog.room -ne $sample.room -or
        $catalog.truncated -or $catalog.all_skill_levels -ne 800 -or $catalog.nodes.Count -ne 241) {
        throw 'The native bridge did not confirm the 241-node Shelldiver catalog in the same process.'
    }

    if ($Action -eq 'ExportCatalog') {
        $table = Export-StockSkillTable $catalog
        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CatalogPath)
        if ([IO.Path]::GetFileName($path) -ne 'native-skill-catalog-max800.json') {
            throw 'The generated skill catalog must be named native-skill-catalog-max800.json.'
        }
        $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllText($temporary,($table | ConvertTo-Json -Depth 13)+[Environment]::NewLine)
            [IO.File]::Move($temporary,$path,$true)
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
        [pscustomobject]@{phase='exported';catalogPath=$path;stockRanks=800;stockNodes=241}
        return
    }

    Confirm-StockCompletion $catalog (Read-StockEndingSave) $sample
} finally {
    $process.Dispose()
}
