#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet(900, 1000, 1100, 1200)] [int]$FishingDepth = 1200,
    [ValidateSet(1000, 1100, 1200)] [int]$MiningDepth = 1200,
    [ValidateRange(1, 3)] [int]$FishingRounds = 2,
    [ValidateRange(1, 6)] [int]$MiningRounds = 4,
    [ValidateRange(0, 6)] [int]$MiningEmptyLimit,
    [ValidateRange(1, 35)] [int]$FishingHarvestSeconds = 15,
    [ValidateRange(1, 35)] [int]$MiningHarvestSeconds = 13,
    [ValidateRange(46, 200)] [int]$PlasmaHoldFrames = 200,
    [ValidateRange(60, 900)] [int]$TimeoutSeconds = 300,
    [switch]$Upgrade,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json'),
    [string]$ControllerRoot = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/autoplay')
)

$ErrorActionPreference = 'Stop'
$control = Join-Path $ControllerRoot 'Invoke-Shelldiver.ps1'
$session = Join-Path $ControllerRoot 'Invoke-ShelldiverSession.ps1'
$station = Join-Path $ControllerRoot 'Invoke-ShelldiverTransmutator.ps1'
$campaign = Join-Path $ControllerRoot 'Invoke-ShelldiverCampaign.ps1'
$Mailbox = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Mailbox)
$stopPath = Join-Path $Mailbox 'session.stop.json'
$sessionLockPath = Join-Path $Mailbox 'session.lock'
$started = [DateTime]::UtcNow
$timer = [Diagnostics.Stopwatch]::StartNew()
$fullBackpackSeconds = 0.0
$gamePid = $null
$lease = $null
$regions = Import-PowerShellDataFile -LiteralPath (Join-Path $ControllerRoot 'ShelldiverRegions.psd1')
$fishRoom = $regions[$FishingDepth].room
$receipt = [ordered]@{
    phase='blocked'; stage='preflight'; pid=$null; startedUtc=$started.ToString('o')
    fishingDepth=$FishingDepth; fishing=@(); fishingCatch=0; fishingDeferredForBackpack=$false
    stationBefore=$null; stationBeforeTransfer=$null; transfer=$null; transferSkipped=$false
    deposited=0; withdrawn=0; stationAfter=$null; remainingEligible=$null; automatedCatchBacklog=$null
    miningDepth=$MiningDepth; mining=$null; obsidianGained=$null
    automaticOutput=$false; payout=$null; payoutDeferred=$false
    groupedUpgrades=$null; groupedUpgradesDeferred=$null
    saveBeforeSha256=$null; saveAfterSha256=$null; error=$null
}

function Get-Budget([int]$Minimum, [int]$Maximum) {
    try {
        $signal = [IO.File]::ReadAllText($stopPath) | ConvertFrom-Json
    } catch [IO.FileNotFoundException] {
        $signal = $null
    }
    if ($signal.requestedTicks -ge $started.Ticks) {
        throw [OperationCanceledException]::new('Shelldiver session stop requested.')
    }
    $remaining = [Math]::Floor($TimeoutSeconds - $timer.Elapsed.TotalSeconds + $fullBackpackSeconds)
    if ($remaining -lt $Minimum) { throw 'The conversion cycle has reached its time budget.' }
    return [int][Math]::Min($remaining, $Maximum)
}

function Assert-IdleIsland {
    try {
        $existing = [IO.File]::Open($sessionLockPath, 'Open', 'Read', 'None')
        $existing.Dispose()
    } catch [IO.FileNotFoundException] {
        # The existing controller creates its lease file on first action.
    } catch [IO.IOException] {
        throw 'Another native Shelldiver session currently owns the mailbox.'
    }
    $state = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds (Get-Budget 1 4)
    if (!$state.pid -or ($gamePid -and $state.pid -ne $gamePid) -or $state.room -ne 'rm_main_island' -or
        $state.inputReady -ne $true -or $state.flags.files_loaded -ne $true -or
        $state.flags.transitioning -or $state.flags.pause -or $state.flags.in_cutscene -or
        $state.flags.is_on_final_cutscene -or $state.flags.player_inventory_open -or
        $state.guiPointer.active -or $state.activeInputFrames -ne 0 -or $state.scene.player.can_use_tool -ne 1) {
        throw 'A ready and idle island in the original resident Shelldiver process is required.'
    }
    if ($state.inputError -and $state.inputError -ne 'Could not publish the game mailbox response.') {
        throw "The native controller reported an input error. $($state.inputError)"
    }
    return $state
}

function Read-Station {
    $state = & $station -Action Status -Mailbox $Mailbox -SavePath $SavePath -ControllerRoot $ControllerRoot
    if ($state.phase -ne 'status' -or $state.unlocked -ne $true -or $state.outputType -notin 1, 2 -or
        $null -eq $state.inventories.player -or $null -eq $state.inventories.shop -or
        $null -eq $state.inventories.input -or $null -eq $state.inventories.output) {
        throw 'The native save did not confirm an unlocked transmutator with typed inventories.'
    }
    if ($state.unsupportedSkills.Count -gt 0) {
        throw "The current station has unsupported cross-automation enabled. $($state.unsupportedSkills -join ', ')"
    }
    if ($state.automaticOutput -eq $true -and
        ($null -eq $state.storeShellCoins -or $state.storeShellCoins -lt 0)) {
        throw 'The original automatic-output save did not report a valid store balance.'
    }
    return $state
}

function Get-StationEligibleCatch($StationState) {
    foreach ($key in $StationState.inventories.player.Keys) {
        if ([int](($key -split ',')[1]) -lt $StationState.outputType) {
            return $true
        }
    }
    return $false
}

try {
    if (!(Test-Path -LiteralPath $Mailbox -PathType Container)) { throw 'A resident Shelldiver mailbox is required.' }
    try {
        $lease = [IO.File]::Open((Join-Path $Mailbox 'conversion-cycle.lock'), 'OpenOrCreate', 'Write', 'None')
    } catch [IO.IOException] {
        throw 'A Shelldiver conversion cycle already owns this mailbox.'
    }
    $initial = Assert-IdleIsland
    $gamePid = $initial.pid
    $receipt.pid = $gamePid
    if ($PlasmaHoldFrames -lt 100) {
        $miningState=& $session -Action Status -Mailbox $Mailbox -SavePath $SavePath
        if ($MiningDepth -notin 1000,1200 -or $miningState.pid -ne $gamePid -or $miningState.room -ne 'rm_main_island' -or
            $miningState.nativeSave.magmaPlasmaChargeFrames -lt 13 -or
            $PlasmaHoldFrames -lt $miningState.nativeSave.magmaPlasmaChargeFrames+11) {
            throw 'A short plasma pulse requires a supported Magma resource expedition and at least the saved native charge plus eleven steps.'
        }
    }
    if ($initial.numbers.total_skill_levels_upgraded -lt 500) {
        throw 'The original save must have unlocked Magma I.'
    }
    $receipt.saveBeforeSha256 = (Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash
    $receipt.stationBefore = Read-Station
    $automaticOutput = $receipt.stationBefore.automaticOutput -eq $true
    $receipt.automaticOutput = $automaticOutput
    if (!$automaticOutput -and $receipt.stationBefore.inventories.shop.Count -ne 0) {
        throw 'The native shop queue must be empty before this conversion cycle.'
    }

    $receipt.stage = 'fishing'
    $playerBefore = [long](($receipt.stationBefore.inventories.player.Values | Measure-Object -Sum).Sum)
    $receipt.fishingDeferredForBackpack = $automaticOutput -and $receipt.stationBefore.queues -and
        (Get-StationEligibleCatch $receipt.stationBefore)
    for ($round = 1; !$receipt.fishingDeferredForBackpack -and $round -le $FishingRounds; ++$round) {
        $null = Assert-IdleIsland
        $beforeExpedition = & $session -Action Status -Mailbox $Mailbox -SavePath $SavePath
        if ($beforeExpedition.pid -ne $gamePid -or $beforeExpedition.room -ne 'rm_main_island' -or !$beforeExpedition.nativeSave.sha256) {
            throw 'The original fishing baseline did not match the resident island.'
        }
        $beforeFishing = $timer.Elapsed.TotalSeconds
        $result = & $session -Action Run -Kind Jellyfish -Rounds 1 -Depth $FishingDepth -HoldResult `
            -HarvestSeconds $FishingHarvestSeconds -Mailbox $Mailbox -SavePath $SavePath -TimeoutSeconds (Get-Budget 20 80)
        if ($FishingDepth -in 1100,1200) { $fullBackpackSeconds += $timer.Elapsed.TotalSeconds-$beforeFishing }
        $trip = [pscustomobject]@{ round=$round; result=$result; finish=$null; catch=$null; automaticCatchRouting=$null }
        $receipt.fishing += $trip
        if ($result.phase -ne 'result' -or $result.pid -ne $gamePid -or $result.room -ne $fishRoom -or
            $result.depth -ne $FishingDepth -or $result.heldResultRound -ne 1 -or $result.oxygen -le 0 -or
            !$result.nativeSave.sha256 -or $null -eq $result.nativeSave.playerJellyfish -or
            (!$result.nativeSave.storageAutoOutput -and $result.nativeSave.playerJellyfish -lt $playerBefore)) {
            throw "The original fishing result for round $round could not be verified."
        }
        $finish = & $session -Action FinishResult -Depth $FishingDepth -ResultVerified -Mailbox $Mailbox -SavePath $SavePath `
            -TimeoutSeconds (Get-Budget 20 25)
        $trip.finish = $finish
        if ($finish.pid -ne $gamePid -or $finish.room -ne 'rm_main_island' -or !$finish.nativeSaveAfter.sha256) {
            throw "The original Finish action did not verify an island save on round $round."
        }
        if ($result.nativeSave.storageAutoOutput) {
            . (Join-Path $PSScriptRoot 'ShelldiverCatchFlow.ps1')
            $held = $result.nativeSave
            $original = $beforeExpedition.nativeSave
            $ended = $finish.nativeSaveAfter
            $heldCatch = $held.playerJellyfish + $held.submarineJellyfish
            $originalCatch = $original.playerJellyfish + $original.submarineJellyfish
            $routing = Compare-NativeCatchPipeline $held $ended
            if (!$routing -or !$original.catchPipeline -or !$held.catchPipeline -or
                !$finish.nativeSaveBefore.sha256 -or $heldCatch -lt $originalCatch) {
                throw "The original automatic fishing catch could not be reconciled on round $round."
            }
            # The underwater result proves the landed catch. Island wallet movement is recorded separately.
            $trip.catch = [long]($heldCatch - $originalCatch)
            $trip.automaticCatchRouting = $routing
        } else {
            if ($finish.nativeSaveAfter.playerJellyfish -ne $result.nativeSave.playerJellyfish -or
                $finish.nativeSaveAfter.submarineJellyfish -ne $result.nativeSave.submarineJellyfish) {
                throw "The original Finish action did not retain the saved fishing catch on round $round."
            }
            $trip.catch = [long]$finish.nativeSaveAfter.playerJellyfish - $playerBefore
        }
        $receipt.fishingCatch += $trip.catch
        $playerBefore = [long]$finish.nativeSaveAfter.playerJellyfish
        if ($FishingDepth -in 1100,1200 -and $result.divePerformance.reason -eq 'dynamic-native-pack-full') { break }
    }
    $receipt.stage = 'transmutator'
    $null = Assert-IdleIsland
    $receipt.stationBeforeTransfer = Read-Station
    if (($receipt.stationBeforeTransfer.automaticOutput -eq $true) -ne $automaticOutput) {
        throw 'Native automatic-output mode changed during the cycle.'
    }
    $stationPlan = $receipt.stationBeforeTransfer.queues
    $eligibleFish = @($receipt.stationBeforeTransfer.inventories.player.Keys | Where-Object {
        [int](($_ -split ',')[1]) -lt $receipt.stationBeforeTransfer.outputType
    })
    $receipt.remainingEligible = [long](($eligibleFish | ForEach-Object {
        $receipt.stationBeforeTransfer.inventories.player[$_]
    } | Measure-Object -Sum).Sum)
    $fillAutomaticStation = $automaticOutput -and $FishingDepth -in 1100,1200
    if ((!$eligibleFish.Count -or (($stationPlan -or !$fillAutomaticStation) -and
        $receipt.stationBeforeTransfer.inputCanAcceptBackpack -ne $true)) -and
        ($automaticOutput -or $receipt.stationBeforeTransfer.inventories.output.Count -eq 0)) {
        $receipt.transferSkipped = $true
    } else {
        $transferAction = if ($automaticOutput -and $stationPlan) { 'TransferReady' }
            elseif ($fillAutomaticStation) { 'TransferAll' } else { 'Transfer' }
        $transferBudget = if ($transferAction -eq 'TransferAll') { Get-Budget 4 240 } else { Get-Budget 4 25 }
        $trade = & $station -Action $transferAction -Mailbox $Mailbox -SavePath $SavePath -ControllerRoot $ControllerRoot `
            -TimeoutSeconds $transferBudget
        $receipt.transfer = $trade
        if ($trade.phase -ne 'transferred' -or $trade.pid -ne $gamePid -or
            $trade.outputType -ne $receipt.stationBeforeTransfer.outputType -or
            ($trade.automaticOutput -eq $true) -ne $automaticOutput -or
            $null -eq $trade.before.player -or $null -eq $trade.after.player) {
            throw 'The station did not confirm a typed native transfer in the original process.'
        }
        $keys = @($trade.before.player.Keys; $trade.after.player.Keys) | Sort-Object -Unique
        foreach ($key in $keys) {
            $type = [int](($key -split ',')[1])
            $delta = [long]$trade.after.player[$key] - [long]$trade.before.player[$key]
            if ($type -lt $trade.outputType -and $delta -lt 0) { $receipt.deposited -= $delta }
            if ($type -eq $trade.outputType -and $delta -gt 0) { $receipt.withdrawn += $delta }
        }
        if ($automaticOutput -and ($receipt.deposited -ne $trade.deposited -or $receipt.withdrawn -ne 0)) {
            throw 'The automatic-output pulse did not match its native typed deposit receipt.'
        }
        if (($receipt.deposited + $receipt.withdrawn) -le 0 -and
            ($transferAction -ne 'TransferReady' -or $trade.stopReason -notin 'input-full','backpack-cleared')) {
            throw 'The station did not confirm a native deposit or withdrawal.'
        }
        if (($receipt.deposited + $receipt.withdrawn) -le 0) { $receipt.transferSkipped = $true }
        $receipt.remainingEligible = [long](($trade.after.player.Keys | Where-Object {
            [int](($_ -split ',')[1]) -lt $trade.outputType
        } | ForEach-Object { $trade.after.player[$_] } | Measure-Object -Sum).Sum)
    }

    $deferredStorageSupported = $false
    if ($automaticOutput -and $MiningDepth -eq 1200 -and $receipt.stationBeforeTransfer.outputType -eq 2) {
        $live = & $session -Action Status -Mailbox $Mailbox -SavePath $SavePath
        $deferredStorageSupported = $live.pid -eq $gamePid -and $live.room -eq 'rm_main_island' -and
            $live.supportsDeferredResourceBacklog -eq $true -and $live.nativeSave.storageAutoOutput -eq $true -and
            $live.nativeSave.transmutatorAutoOutput -eq $true -and $live.nativeSave.transmutatorOutputType -eq 2
    }
    if ($deferredStorageSupported -and $live.nativeSave.playerJellyfish -gt 0 -and
        $live.nativeSave.playerJellyfishSlotCapacity -gt 0 -and
        $live.nativeSave.playerRedJellyfishCompatibleSpace -lt $live.nativeSave.playerJellyfishSlotCapacity) {
        $receipt.payoutDeferred = $true
        $receipt.phase = 'queued'
        $receipt.stage = 'awaiting-resource-backpack-space'
        $receipt.resourceBackpackSpace = @{saveSha256=$live.nativeSave.sha256;pid=$live.pid;frame=$live.frame;
            speciesId=11;rarity=0;compatibleSpace=$live.nativeSave.playerRedJellyfishCompatibleSpace;
            slotCapacity=$live.nativeSave.playerJellyfishSlotCapacity;carried=$live.nativeSave.playerJellyfish}
        $receipt.stationAfter = Read-Station
        return $receipt
    }
    if ($receipt.remainingEligible -gt 0 -and $automaticOutput -and !$deferredStorageSupported) {
        $receipt.payoutDeferred = $true
        $receipt.phase = 'queued'
        $receipt.stage = 'awaiting-compatible-input'
        $receipt.stationAfter = Read-Station
        return $receipt
    }

    $receipt.stage = 'mining'
    $null = Assert-IdleIsland
    $mine = & $session -Action Run -Kind Resource -Depth $MiningDepth -Rounds $MiningRounds -ReturnBetweenRounds:($MiningDepth -ne 1000) `
        -BatchSettlement -HarvestSeconds $MiningHarvestSeconds -PlasmaHoldFrames $PlasmaHoldFrames `
        -StopAfterEmptyResourceRounds $MiningEmptyLimit -DeferShopPayout:$automaticOutput `
        -Mailbox $Mailbox -SavePath $SavePath `
        -TimeoutSeconds (Get-Budget 20 180)
    $receipt.mining = $mine
    $nativeRounds = [int]$mine.roundsCompleted
    $spaceStop = $mine.backpackSpaceStop
    $verifiedBackpackStop = $MiningDepth -eq 1200 -and $mine.stoppedForBackpackSpace -eq $true -and
        $nativeRounds -ge 1 -and $nativeRounds -lt $MiningRounds -and $spaceStop.pid -eq $gamePid -and
        $spaceStop.frame -gt 0 -and $spaceStop.saveSha256 -eq $mine.verifiedSaveAfter.sha256 -and
        $spaceStop.speciesId -eq 11 -and $spaceStop.rarity -eq 0 -and $spaceStop.slotCapacity -gt 0 -and
        $null -ne $spaceStop.compatibleSpace -and $spaceStop.compatibleSpace -ge 0 -and
        $spaceStop.compatibleSpace -eq $mine.verifiedSaveAfter.playerRedJellyfishCompatibleSpace -and
        $spaceStop.slotCapacity -eq $mine.verifiedSaveAfter.playerJellyfishSlotCapacity -and
        (($spaceStop.reason -eq 'no-compatible-slot' -and $spaceStop.compatibleSpace -eq 0) -or
        ($spaceStop.reason -eq 'native-full-less-than-one-stack' -and $spaceStop.priorFull -eq $true -and
            $spaceStop.compatibleSpace -gt 0 -and $spaceStop.compatibleSpace -lt $spaceStop.slotCapacity))
    if ($verifiedBackpackStop) { $receipt.resourceBackpackSpace = $spaceStop }
    $miningCompleted = $nativeRounds -eq $MiningRounds -or $verifiedBackpackStop -or
        ($MiningEmptyLimit -gt 0 -and $mine.stoppedForLowYield -eq $true -and
            $nativeRounds -ge $MiningEmptyLimit -and $nativeRounds -lt $MiningRounds -and
            $mine.emptyResourceStreak -ge $MiningEmptyLimit)
    $savedBacklog = $mine.automatedCatchBacklog
    $backlogVerified = $deferredStorageSupported -and $mine.automatedCatchBacklogDeferred -eq $true -and
        $savedBacklog.pid -eq $gamePid -and $savedBacklog.frame -gt 0 -and $savedBacklog.saveSha256 -eq $mine.verifiedSaveAfter.sha256 -and
        !(@('playerJellyfish','submarineJellyfish','transmutatorInputJellyfish','transmutatorOutputJellyfish',
            'storeQueuedJellyfish','storeShellCoins') | Where-Object {
                $null -eq $savedBacklog.$_ -or $savedBacklog.$_ -ne $mine.verifiedSaveAfter.$_
            })
    if ($backlogVerified) { $receipt.automatedCatchBacklog = $savedBacklog }
    if ($mine.pid -ne $gamePid -or $mine.room -ne 'rm_main_island' -or !$miningCompleted -or
        $mine.nativeBalanceVerified -ne $true -or !$mine.saveBefore.sha256 -or !$mine.verifiedSaveAfter.sha256 -or
        ($mine.stoppedForBackpackSpace -eq $true -and !$verifiedBackpackStop) -or
        $null -eq $mine.saveBefore.wallet.obsidian -or $null -eq $mine.verifiedSaveAfter.wallet.obsidian -or
        (!$backlogVerified -and ($mine.verifiedSaveAfter.playerJellyfish -ne 0 -or $mine.verifiedSaveAfter.submarineJellyfish -ne 0)) -or
        ($mine.automatedCatchBacklogDeferred -eq $true -and !$backlogVerified) -or
        (!$automaticOutput -and ($mine.verifiedSaveAfter.storeQueuedJellyfish -ne 0 -or
            $mine.verifiedSaveAfter.storeShellCoins -ne 0)) -or
        ($automaticOutput -and ($mine.shopPayoutDeferred -ne $true -or
            $null -eq $mine.verifiedSaveAfter.storeQueuedJellyfish -or $mine.verifiedSaveAfter.storeQueuedJellyfish -lt 0 -or
            $null -eq $mine.verifiedSaveAfter.storeShellCoins -or $mine.verifiedSaveAfter.storeShellCoins -lt 0)) -or
        @($mine.rounds).Count -ne $nativeRounds -or
        @($mine.rounds | Where-Object { $_.depth -ne $MiningDepth -or $_.nativeOxygenLoss }).Count -ne 0) {
        throw "Mining at $MiningDepth meters and the original batch settlement were not fully verified."
    }
    $receipt.obsidianGained = $mine.verifiedSaveAfter.wallet.obsidian - $mine.saveBefore.wallet.obsidian
    if ($receipt.obsidianGained -lt 0) { throw 'The original mining batch unexpectedly lost saved obsidian.' }

    if ($automaticOutput) {
        $receipt.stage = 'payout'
        $null = Assert-IdleIsland
        $afterMining = Read-Station
        if ($afterMining.automaticOutput -ne $true) { throw 'Native automatic-output mode changed during mining.' }
        # Even one fish in a partial stack remains stock waiting work. Drain only an idle pipeline.
        $receipt.payoutDeferred = $backlogVerified -or $afterMining.inventories.input.Count -gt 0 -or
            $afterMining.inventories.output.Count -gt 0 -or $afterMining.inventories.shop.Count -gt 0
        if (!$receipt.payoutDeferred -and $afterMining.storeShellCoins -gt 0) {
            $payout = & $session -Action Settle -Mailbox $Mailbox -SavePath $SavePath -TimeoutSeconds (Get-Budget 20 150)
            $receipt.payout = $payout
            $settled = $payout.nativeShopSettlement
            $nativePayoutVerified = $settled.verified -eq $true -and
                $settled.saveSha256 -eq $payout.nativeSaveAfter.sha256 -and
                $settled.walletShells -eq $payout.nativeSaveAfter.shellCoins -and
                $settled.remainingShopShells -eq 0 -and $settled.queuedJellyfish -eq 0
            if ($payout.pid -ne $gamePid -or $payout.room -ne 'rm_main_island' -or
                !$payout.nativeSaveBefore.sha256 -or !$payout.nativeSaveAfter.sha256 -or
                $null -eq $payout.nativeSaveBefore.shellCoins -or $null -eq $payout.nativeSaveBefore.storeShellCoins -or
                $null -eq $payout.nativeSaveAfter.shellCoins -or
                (!$nativePayoutVerified -and
                    $payout.nativeSaveAfter.shellCoins -lt ($payout.nativeSaveBefore.shellCoins + $payout.nativeSaveBefore.storeShellCoins)) -or
                $payout.nativeSaveAfter.storeQueuedJellyfish -ne 0 -or $payout.nativeSaveAfter.storeShellCoins -ne 0) {
                throw 'The original automatic-output chest payout was not verified.'
            }
        }
    }

    if ($Upgrade -and $receipt.payoutDeferred) {
        $receipt.groupedUpgradesDeferred = 'The native station still has fish to convert or send to the store.'
    } elseif ($Upgrade) {
        $receipt.stage = 'upgrades'
        $null = Assert-IdleIsland
        $purchases = & $campaign -Rounds 0 -Cycles 1 -Depth $MiningDepth -Kind Resource -UseStockCatalog `
            -Mailbox $Mailbox -SavePath $SavePath -TimeoutSeconds (Get-Budget 30 180)
        $receipt.groupedUpgrades = $purchases
        if ($purchases.phase -ne 'completed' -or $purchases.pid -ne $gamePid -or
            $purchases.cyclesCompleted -ne 1 -or !$purchases.nativeSaveAfter.sha256) {
            throw "Grouped native upgrades were not verified. $($purchases.error)"
        }
    }
    $receipt.stage = 'final-verification'
    $null = Assert-IdleIsland
    $receipt.stationAfter = Read-Station
    $receipt.phase = 'completed'
    $receipt.stage = 'completed'
} catch {
    $receipt.phase = if ($_.Exception.GetBaseException() -is [OperationCanceledException]) { 'stopped' } else { 'blocked' }
    $receipt.error = $_.Exception.Message
} finally {
    if ($receipt.saveBeforeSha256) {
        try { $receipt.saveAfterSha256 = (Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash } catch {
            if ($receipt.phase -eq 'completed') {
                $receipt.phase = 'blocked'
                $receipt.stage = 'final-verification'
                $receipt.error = 'The final original save hash could not be read.'
            }
        }
    }
    if ($lease) { $lease.Dispose() }
}
$receipt.finishedUtc = [DateTime]::UtcNow.ToString('o')
$receipt.elapsedMs = $timer.ElapsedMilliseconds
[pscustomobject]$receipt
