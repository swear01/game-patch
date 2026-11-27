#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [ValidateRange(2.0, 30.0)] [double]$SampleSeconds = 4.0,
    [ValidateRange(1, 999)] [int]$NearFullCount = 80
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ShelldiverMailbox.ps1')
$Mailbox = (Resolve-Path -LiteralPath $Mailbox).ProviderPath
$snapshotPath = Join-Path $Mailbox 'snapshot.json'
$returnPath = Join-Path $Mailbox 'dive-return.json'
$badgePath = Join-Path $Mailbox 'catch-badge.json'
$capturePath = Join-Path ([IO.Path]::GetTempPath()) ("shelldiver-watch-" + [Guid]::NewGuid().ToString('N') + '.png')
$captureScript = Join-Path $PSScriptRoot 'Get-ShelldiverFrame.ps1'
$badgeScript = Join-Path $PSScriptRoot 'Get-ShelldiverCatchBadge.ps1'
$clock = [Diagnostics.Stopwatch]::StartNew()
$nextCapture = 0.0
$nextWrite = 0.0
$job = $null
$epoch = $null

function Read-CatchWatchJson([string]$Path) {
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($Path, 'Open', 'Read', $share)
        try {
            $reader = [IO.StreamReader]::new($stream)
            try { return $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch [IO.IOException], [Management.Automation.RuntimeException] { return }
}

function Read-BadgeWatchSnapshot {
    $sample = Read-CatchWatchJson $snapshotPath
    if (!$sample.pid -or !$sample.room -or !$sample.writtenUtc -or $null -eq $sample.frame) { return }
    try { $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$sample.writtenUtc).TotalSeconds }
    catch { return }
    if ($age -ge 0 -and $age -le 2) { return $sample }
}

function New-CatchWatchEpoch($Sample, [bool]$AllowInitialNative) {
    return @{
        pid=[int]$Sample.pid; room=$Sample.room; frame=[long]$Sample.frame; lastFrame=[long]$Sample.frame
        initialBubbles=[long]$Sample.projectiles.bubble; transition=[bool]$Sample.flags.transitioning
        sawResult=$false; armed=$AllowInitialNative; count=$null; nearFull=$false
        firstFullFrame=$null; lastFullFrame=$null; firstFullSource=$null; source=$null
        firstFullUtc=$null; captureElapsedMs=$null
    }
}

function Get-CatchWatchNativeSource($Sample) {
    $player=$Sample.scene.player
    if ($Sample.room -notlike 'rm_ocean_*' -or $Sample.flags.transitioning -or !($player.frame -gt 0) -or
        $player.frame -gt $Sample.frame -or $Sample.frame-$player.frame -gt 24) { return }
    foreach ($flag in @($player.is_inventory_full,$player.inventory_full,$Sample.flags.is_inventory_full)) {
        if ($flag -eq $true) { return 'native-inventory-flag' }
    }
    if ($player.new_fish_bubble_amount_full -eq $true) { return 'native-hud-latch' }
    $pack=$Sample.inventories.player
    if ($pack.slotCount -gt 0 -and $pack.slotCapacity -gt 0 -and $pack.total -ge $pack.slotCount*$pack.slotCapacity) {
        return 'native-capacity'
    }
}

function Add-CatchWatchFull($Epoch, [long]$EvidenceFrame, [string]$Source, [string]$AtUtc) {
    if (!$Epoch.firstFullFrame) {
        $Epoch.firstFullFrame=$EvidenceFrame
        $Epoch.firstFullSource=$Source
        $Epoch.firstFullUtc=$AtUtc
    }
    if ($EvidenceFrame -ge $Epoch.lastFullFrame) {
        $Epoch.lastFullFrame=$EvidenceFrame
        $Epoch.source=$Source
    }
}

function Write-CatchObservation($Sample, $Epoch) {
    $record = [ordered]@{
        pid = [int]$Sample.pid; room = $Sample.room
        diveStartFrame = $Epoch.frame
        observedFrame = [long]$Sample.frame
        observedUtc = ([DateTimeOffset]::UtcNow.ToString('o'))
        snapshotUtc = $Sample.writtenUtc
        nativePlayerFrame = $Sample.scene.player.frame
        count = $Epoch.count
        full = [bool]$Epoch.firstFullFrame
        firstFullFrame = $Epoch.firstFullFrame
        lastFullFrame = $Epoch.lastFullFrame
        firstFullSource = $Epoch.firstFullSource
        firstFullUtc = $Epoch.firstFullUtc
        source = $Epoch.source
        elapsedMs = $Epoch.captureElapsedMs
    }
    $temporary = "$badgePath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $record -Compress))
        Publish-ShelldiverMailboxFile $temporary $badgePath
    } finally { [IO.File]::Delete($temporary) }
}

try {
    $lock = [IO.File]::Open((Join-Path $Mailbox 'catch-watch.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch [IO.IOException] {
    if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -in 32, 33) {
        Write-Verbose 'A Shelldiver catch watcher is already running for this mailbox.'
        return
    }
    throw
}

try {
    while ($true) {
        $sample = Read-BadgeWatchSnapshot
        if (!$sample) { Start-Sleep -Milliseconds 100; continue }
        try {
            if ($epoch -and $sample.scene.player.can_use_tool -eq 0 -and $sample.room -like 'rm_ocean_*' -and
                $epoch.pid -eq $sample.pid -and $epoch.room -eq $sample.room -and !$epoch.sawResult) {
                $checkpoint=Read-CatchWatchJson $returnPath
                if ($checkpoint.pid -eq $sample.pid -and $checkpoint.expectedHash -cmatch '^[0-9A-F]{64}$' -and
                    $checkpoint.stateFrame -ge $epoch.frame -and $checkpoint.stateFrame -le $sample.frame) {
                    $epoch.sawResult=$true
                }
            }
            $first=!$epoch
            $sameRoomRetry=$epoch -and !$sample.flags.transitioning -and $sample.scene.player.can_use_tool -eq 1 -and
                ($epoch.transition -or $epoch.sawResult)
            if ($first -or $sample.pid -ne $epoch.pid -or $sample.room -ne $epoch.room -or
                $sample.frame -lt $epoch.lastFrame -or $sameRoomRetry) {
                $epoch=New-CatchWatchEpoch $sample ($first -and !$sample.flags.transitioning)
                $nextCapture=0.0
                $nextWrite=0.0
            }
            $epoch.lastFrame=$sample.frame
            if ($sample.flags.transitioning) { $epoch.transition=$true }

            $underwater=$sample.room -like 'rm_ocean_*'
            $signal=Get-CatchWatchNativeSource $sample
            if ($underwater -and !$sample.flags.transitioning -and $sample.scene.player.frame -gt 0 -and
                $sample.frame-$sample.scene.player.frame -le 24) {
                if (!$signal) { $epoch.armed=$true }
                if ($signal -and ($epoch.armed -or $signal -eq 'native-capacity')) {
                    if (!$epoch.firstFullFrame) { $nextWrite=0.0 }
                    Add-CatchWatchFull $epoch $sample.frame $signal ([DateTimeOffset]::UtcNow.ToString('o'))
                }
            }

            if ($job -and $job.State -in 'Completed','Failed','Stopped') {
                try {
                    $result=Receive-Job -Job $job
                    if ($result -and $underwater -and !$sample.flags.transitioning -and !$epoch.sawResult -and
                        $result.pid -eq $sample.pid -and $result.room -eq $sample.room -and $result.diveStartFrame -eq $epoch.frame -and
                        $result.frame -ge $epoch.frame -and $result.frame -le $sample.frame -and
                        ([DateTimeOffset]::UtcNow-[DateTimeOffset]$result.utc).TotalSeconds -le 7.0) {
                        $epoch.captureElapsedMs=$result.elapsedMs
                        if ($result.value -is [int]) {
                            $epoch.count=$result.value
                            $epoch.nearFull=$result.value -ge $NearFullCount
                        }
                        if ($result.value -ceq 'full' -and $epoch.armed) {
                            Add-CatchWatchFull $epoch $result.frame 'ocr-full' $result.utc
                        }
                        $nextWrite=0.0
                    }
                } finally {
                    Remove-Job -Job $job -Force
                    $job=$null
                }
            }
            $now=$clock.Elapsed.TotalSeconds
            if ($now -ge $nextWrite) {
                Write-CatchObservation $sample $epoch
                $nextWrite=$now+1.0
            }
            if (!$job -and $underwater -and !$sample.flags.transitioning -and !$sample.flags.pause -and !$epoch.sawResult -and
                !$epoch.firstFullFrame -and $epoch.armed -and $now -ge $nextCapture -and
                ($sample.projectiles.bubble -gt $epoch.initialBubbles -or $sample.scene.player.new_fish_bubble_amount -gt 0)) {
                $nextCapture=$now+$(if ($epoch.nearFull) { 2.0 } else { $SampleSeconds })
                $job=Start-ThreadJob -ArgumentList @($captureScript,$badgeScript,$capturePath,$Mailbox,$sample.pid,$sample.room,$sample.frame,$epoch.frame) -ScriptBlock {
                    param($CaptureScript,$BadgeScript,$CapturePath,$Mailbox,$GamePid,$Room,$Frame,$DiveFrame)
                    $ErrorActionPreference='Stop'
                    $captureClock=[Diagnostics.Stopwatch]::StartNew()
                    $utc=[DateTimeOffset]::UtcNow.ToString('o')
                    $capture=& $CaptureScript -OutputPath $CapturePath -Mailbox $Mailbox
                    if (!$capture.foregroundUnchanged -or $capture.pid -ne $GamePid -or $capture.room -ne $Room) { return }
                    $value=& $BadgeScript -FramePath $capture.path
                    [pscustomobject]@{pid=$GamePid;room=$Room;frame=$Frame;diveStartFrame=$DiveFrame;utc=$utc;
                        value=$value;elapsedMs=$captureClock.ElapsedMilliseconds}
                }
            }
        } catch {
            Write-Verbose ("Skipping catch observation. " + $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    if ($job) { Remove-Job -Job $job -Force }
    [IO.File]::Delete($capturePath)
    $lock.Dispose()
}
