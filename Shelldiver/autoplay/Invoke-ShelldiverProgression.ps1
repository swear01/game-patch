#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Run', 'Status')] [string]$Action = 'Plan',
    [ValidateSet('MaxRanks','Ending')] [string]$Profile = 'MaxRanks',
    [ValidateRange(0, 5000)] [int]$MaxActions = 0,
    [ValidateSet(1100, 1200)] [int]$FishingDepth = 1200,
    [ValidateSet(0, 1000, 1200)] [int]$MiningDepth = 0,
    [ValidateRange(1, 6)] [int]$MiningRounds = 3,
    [ValidateRange(1, 35)] [int]$MiningHarvestSeconds = 18,
    [ValidateRange(1, 10)] [int]$MaxExchanges = 3,
    [ValidateRange(1, 32)] [int]$MaxPurchases = 6,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json'),
    [string]$ControllerRoot = $PSScriptRoot,
    [string]$NativeCatalogReceipt
)

$ErrorActionPreference = 'Stop'
$Mailbox = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Mailbox)
$statePath = Join-Path $Mailbox 'progression.json'
if ($Action -eq 'Status') {
    if ([IO.File]::Exists($statePath)) {
        return (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -AsHashtable)
    }
    return @{ phase='idle' }
}

if ($Profile -eq 'MaxRanks') {
    if ($FishingDepth -ne 1200 -or $MiningDepth -notin 0,1200) {
        throw 'The MaxRanks profile uses 1200m for fishing and obsidian. Exclusive biome materials are planned separately.'
    }
    if (!$PSBoundParameters.ContainsKey('MaxPurchases')) { $MaxPurchases = 24 }
    if (!$PSBoundParameters.ContainsKey('MaxExchanges')) { $MaxExchanges = 8 }
    if (!$NativeCatalogReceipt) { $NativeCatalogReceipt = Join-Path (Split-Path -Parent $ControllerRoot) 'native-skill-catalog-max800.json' }
}
$session = Join-Path $ControllerRoot 'Invoke-ShelldiverSession.ps1'
$dive = Join-Path $ControllerRoot 'Invoke-ShelldiverDive.ps1'
$control = Join-Path $ControllerRoot 'Invoke-Shelldiver.ps1'
$conversion = Join-Path $ControllerRoot 'Invoke-ShelldiverConversionCycle.ps1'
$alchemy = Join-Path $ControllerRoot 'Invoke-ShelldiverAlchemy.ps1'
$upgrade = Join-Path $ControllerRoot 'Invoke-ShelldiverUpgrade.ps1'
$resumeHarvest = Join-Path $ControllerRoot 'Invoke-ShelldiverResumeHarvest.ps1'
$transmutator = Join-Path $ControllerRoot 'Invoke-ShelldiverTransmutator.ps1'
$ending = Join-Path $ControllerRoot 'Invoke-ShelldiverEnding.ps1'
$campaign = Join-Path $ControllerRoot 'Invoke-ShelldiverCampaign.ps1'
$catalog = (Get-Content -Raw -LiteralPath (Join-Path $ControllerRoot 'skill-prices.original.json') | ConvertFrom-Json -AsHashtable).nodes
$regions = Import-PowerShellDataFile -LiteralPath (Join-Path $ControllerRoot 'ShelldiverRegions.psd1')
$walletFields = [ordered]@{
    shells='shell_coins'; scrap='scrap_coins'; crystals='crystal_coins'
    mushrooms='mushroom_coins'; obsidian='obsidian_coins'; lifeVials='flask_coins'
}
$finals = @('o_skill_flask_final','o_skill_obsidian_final','o_skill_crystal_final','o_skill_mushroom_final','o_skill_scrap_final')
$support = [ordered]@{
    o_skill_submarine_recover=1
    o_skill_submarine_recover_all=1
    o_skill_shock_frequency=1
    o_skill_shock_resistance_10=1
    o_skill_bubble_smite_threshold=1
    o_skill_bubble_damage_08=10
    o_skill_jellyfish_transmutator=1
    o_skill_transmutator_slots_01=1
    o_skill_transmutator_slots_02=1
    o_skill_transmutator_auto_output=1
    o_skill_transmutator_speed_01=5
    o_skill_transmutator_speed_02=5
    o_skill_transmutator_golden=1
    o_skill_transmutator_speed_03=1
    o_skill_store_speed_08=4
    o_skill_biovalue_silver=1
}
$redWeaponTargets = [ordered]@{
    o_skill_bubble_smite_threshold=1
    o_skill_bubble_damage_08=10
    o_skill_bubble_critical_damage_01=4
    o_skill_bubble_critical_damage_02=2
    o_skill_bubble_speed_02=2
    o_skill_bubble_first_strike_01=4
    o_skill_bubble_first_strike_02=2
    o_skill_bubble_critical_chance_02=5
    o_skill_bubble_critical_damage_03=2
    o_skill_bubble_execute_01=1
    o_skill_bubble_firerate_03=2
}
$magmaThroughputTargets = [ordered]@{
    o_skill_plasma_explosion_chance_02=2
    o_skill_plasma_explosion_size=1
    o_skill_plasma_lightning_chance_02=1
    o_skill_robot_number_01=3
    o_skill_robot_damage_01=6
    o_skill_robot_firerate_01=1
    o_skill_robot_firerate_02=1
    o_skill_entity_spawn_10=1
}
$hammockPrice = [decimal]10000000000000000
$exchangePrice = [decimal]100000000000000
$stopPath = Join-Path $Mailbox 'session.stop.json'
$started = [DateTime]::UtcNow
$failures = @{}
$common = @{Mailbox=$Mailbox; SavePath=$SavePath}
$gamePid = $null
$completed = 0
$recoveredMining = 0
$maxRankProof = $null
$script:maxRankLastNode = $null
$maxRankCrossPerks = @('o_skill_transmutator_sell','o_skill_store_transmutate')
$script:progressionCrossAutomation = $null
$script:unconfirmedShopCredit = $null
$script:materialRoundYield = @{}
$maxRankOrePriority = $maxRankCrossPerks + @(
    'o_skill_alchemy_station_dc_01','o_skill_alchemy_station_dc_02',
    'o_skill_alchemy_station_speed_01','o_skill_alchemy_station_speed_02',
    'o_skill_transmutator_speed_03','o_skill_store_speed_10','o_skill_bubble_size_02'
)
$maxRankCoreVials = @(
    'o_skill_shock_resistance_10','o_skill_bubble_damage_10','o_skill_plasma_damage_10',
    'o_skill_transmutator_golden','o_skill_biovalue_amount_02','o_skill_biovalue_amount_10',
    'o_skill_faster_output_10','o_skill_double_plasma','o_skill_oxygen_tank_10',
    'o_skill_plasma_range_04','o_skill_plasma_ultra_charge','o_skill_plasma_damage_oxygen',
    'o_skill_bubble_damage_oxygen','o_skill_plasma_explosion_damage_02'
)
$maxRankPriority = @(
    'o_skill_submarine','o_skill_submarine_recover','o_skill_submarine_recover_all','o_skill_entity_spawn_10',
    'o_skill_faster_output_01','o_skill_storage_auto_output','o_skill_transmutator_auto_output'
) + $maxRankCoreVials + $maxRankOrePriority
# Original field effects break ties only when prices use the same currency and amount.
$maxRankFieldBenefit = @{
    o_skill_biodiversity_magma=100; o_skill_chain_bubble=160; o_skill_chain_bubble_number=140
    o_skill_bubble_firerate_03=150; o_skill_bubble_first_strike_02=120
    o_skill_bubble_critical_chance_02=180; o_skill_bubble_critical_damage_03=100; o_skill_bubble_execute_02=140
    o_skill_starfish_number_02=110; o_skill_starfish_firerate_02=85; o_skill_starfish_damage_02=75
    o_skill_friendly_bubble_chance_02=45; o_skill_friendly_bubble_damage_02=25
    o_skill_friendly_bubble_damage_10=75; o_skill_friendly_bubble_size_02=35
}

function Read-ProgressionSave {
    for ($attempt = 0; $attempt -lt 5; ++$attempt) {
        try {
            $text = [IO.File]::ReadAllText($SavePath).Trim()
            if (!$text.StartsWith('{')) {
                $bytes = [Convert]::FromHexString($text)
                if ($bytes.Length -lt 16) { throw [FormatException]::new('Incomplete save header.') }
                $size = [BitConverter]::ToInt32($bytes,12)
                if ($size -le 0 -or $size -gt $bytes.Length-16) { throw [FormatException]::new('Incomplete save payload.') }
                $text = [Text.Encoding]::UTF8.GetString($bytes,16,$size)
            }
            $doc = [Text.Json.JsonDocument]::Parse($text)
            try {
                $root = $doc.RootElement
                $global = [Text.Json.JsonElement]::new()
                if ($root.TryGetProperty('global',[ref]$global)) { $root = $global }
                $wallet = [ordered]@{}
                foreach ($currency in $walletFields.Keys) {
                    $wallet[$currency] = $root.GetProperty($walletFields[$currency]).GetDecimal()
                }
                $ranks = @{}
                $total = 0
                foreach ($entry in $root.GetProperty('skills_saved').EnumerateObject()) {
                    $rank = [int]$entry.Value.GetDecimal()
                    $ranks[$entry.Name] = $rank
                    $total += $rank
                }
                $flag = [Text.Json.JsonElement]::new()
                $finished = $root.TryGetProperty('has_played_hammock_cutscene',[ref]$flag) -and $flag.ValueKind -eq [Text.Json.JsonValueKind]::True
                $alchemyPending = $false
                foreach ($field in 'alchemy_shell_coins','store_flask_coins') {
                    $balance = [Text.Json.JsonElement]::new()
                    if ($root.TryGetProperty($field,[ref]$balance) -and $balance.GetDecimal() -gt 0) {
                        $alchemyPending = $true
                    }
                }
                return @{ wallet=$wallet; ranks=$ranks; rank=$total; finished=$finished; alchemyPending=$alchemyPending }
            } finally { $doc.Dispose() }
        } catch [IO.IOException], [FormatException], [Text.Json.JsonException], [Collections.Generic.KeyNotFoundException] {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 45
        }
    }
}

function Get-IslandStatus([switch]$Preview) {
    $state = & $session -Action Status @common
    if (!$state.inputReady -or !$state.pid -or !$state.nativeSave) {
        throw 'The resident Shelldiver telemetry or native save is unavailable.'
    }
    if ($Preview) { return $state }
    if ($gamePid -and $state.pid -ne $gamePid) { throw 'Shelldiver restarted during progression.' }
    if ($state.room -ne 'rm_main_island' -or $state.canUseTool -ne 1 -or
        $state.activeInputFrames -ne 0 -or $state.virtualPointerActive) {
        throw 'Progression requires the resident Shelldiver game on its settled island.'
    }
    Assert-SessionMailboxIdle
    return $state
}

function Assert-SessionMailboxIdle {
    $lock = Join-Path $Mailbox 'session.lock'
    if ([IO.File]::Exists($lock)) {
        try {
            $probe = [IO.File]::Open($lock,'Open','Read','ReadWrite')
            $probe.Dispose()
        } catch [IO.FileNotFoundException] {
        } catch [IO.IOException] {
            throw 'A live Shelldiver session is already using this mailbox.'
        }
    }

}

function Add-ProgressionRequirement([string]$Id, [int]$Target, $Saved, $Required, $Unpriced) {
    if (!$Id -or [int]$Saved.ranks[$Id] -ge $Target -or [int]$Required[$Id] -ge $Target) { return }
    $Required[$Id] = $Target
    $node = $catalog[$Id]
    if (!$node -or $node.status -ne 'constant' -or $node.maxRank -lt $Target) {
        $Unpriced.Add($Id)
        return
    }
    foreach ($parent in $node.needsMaxLevel) {
        $parentTarget = [int]$catalog[$parent].maxRank
        if (!$parentTarget) { $Unpriced.Add($parent); continue }
        Add-ProgressionRequirement $parent $parentTarget $Saved $Required $Unpriced
    }
    foreach ($parent in $node.needsAnyLevel) {
        Add-ProgressionRequirement $parent 1 $Saved $Required $Unpriced
    }
}

function Test-ProgressionPrerequisites($Node, $Ranks) {
    foreach ($parent in $Node.needsAnyLevel) {
        if ([int]$Ranks[$parent] -lt 1) { return $false }
    }
    foreach ($parent in $Node.needsMaxLevel) {
        $maximum = [int]$catalog[$parent].maxRank
        if (!$maximum -or [int]$Ranks[$parent] -lt $maximum) { return $false }
    }
    return $true
}

function Test-ProgressionCrossAutomation {
    if ($null -eq $script:progressionCrossAutomation) {
        $script:progressionCrossAutomation = $false
        if ([IO.File]::Exists($transmutator) -and [IO.File]::Exists($conversion)) {
            try {
                $station = & $transmutator -Action Status -TimeoutSeconds 8 -ControllerRoot $ControllerRoot @common
                $script:progressionCrossAutomation = $station.phase -eq 'status' -and $station.crossAutomation.sellOnTransmute -is [bool] -and
                    $station.crossAutomation.transmuteOnSale -is [bool] -and !$station.unsupportedSkills.Count
            } catch [OperationCanceledException] {
                throw
            } catch {
                Write-Verbose "Could not verify support for stock cross-automation: $($_.Exception.Message)"
            }
        }
    }
    return $script:progressionCrossAutomation
}

function Test-ProgressionGoldenOutput($Saved) {
    $hasCross = $Saved.ranks.o_skill_transmutator_sell -ge 1 -or $Saved.ranks.o_skill_store_transmutate -ge 1
    return $Profile -eq 'MaxRanks' -and $Saved.ranks.o_skill_jellyfish_transmutator -ge 1 -and
        $Saved.ranks.o_skill_transmutator_golden -ge 1 -and $Saved.ranks.o_skill_transmutator_auto_output -ge 1 -and
        [IO.File]::Exists($transmutator) -and (!$hasCross -or (Test-ProgressionCrossAutomation))
}

function Get-ProgressionPlasmaPulse($Plan, $State) {
    $charge = $State.nativeSave.magmaPlasmaChargeFrames
    if ($Profile -eq 'MaxRanks' -and $Plan.depth -in 500,900,1200 -and $charge -ge 13 -and $charge -le 59) {
        return [int][Math]::Clamp($charge+35,46,70)
    }
    return 100
}

function Finish-ProgressionGoldenCatch([int]$Depth) {
    $held = & $session -Action Run -Depth $Depth -Kind Jellyfish -Rounds 1 -FillBackpack -HoldResult @common
    if ($held.phase -ne 'result' -or $held.pid -ne $gamePid -or $held.depth -ne $Depth -or
        $held.room -ne $regions[$Depth].room -or $held.oxygen -le 0 -or !$held.nativeSave.sha256) {
        throw 'The native golden fishing expedition did not verify its held result.'
    }
    $landed = & $session -Action FinishResult -Depth $Depth -ResultVerified -TimeoutSeconds 45 @common
    if ($landed.pid -ne $gamePid -or $landed.room -ne 'rm_main_island' -or
        !$landed.nativeSaveBefore.sha256 -or !$landed.nativeSaveAfter.sha256) {
        throw 'The native golden fishing expedition did not settle on the original island.'
    }
    if ($held.nativeSave.storageAutoOutput) {
        . (Join-Path $ControllerRoot 'ShelldiverCatchFlow.ps1')
        $routing = Compare-NativeCatchPipeline $held.nativeSave $landed.nativeSaveAfter
        if (!$routing) { throw 'The original golden fishing landing did not reconcile with native storage routing.' }
    } elseif ($landed.nativeSaveAfter.playerJellyfish -ne $held.nativeSave.playerJellyfish -or
        $landed.nativeSaveAfter.submarineJellyfish -ne $held.nativeSave.submarineJellyfish) {
        throw 'The original golden fishing landing did not retain the native catch.'
    }
    return @{pid=$gamePid;phase='landed';nativeBalanceVerified=$true;held=$held;landed=$landed;automaticCatchRouting=$routing}
}

function Invoke-ProgressionMaterialTrips($Plan, $State, [int]$PlasmaPulse) {
    . (Join-Path $ControllerRoot 'ShelldiverCatchFlow.ps1')
    $baseline = $State.nativeSave
    $rounds = [Collections.Generic.List[object]]::new()
    $currency = $Plan.currency

    for ($round = 1; $round -le $Plan.rounds; ++$round) {
        if (Test-ProgressionStopped) { break }
        $before = $State.nativeSave
        if (!$before.sha256 -or $null -eq $before.wallet[$currency] -or
            $before.catchPipeline.inventories.Count -ne 5) {
            throw 'The original material expedition requires a saved wallet and all five catch inventories.'
        }
        $held = & $session -Action Run -Depth $Plan.depth -Kind Resource -Rounds 1 -HoldResult `
            -HarvestSeconds $MiningHarvestSeconds -PlasmaHoldFrames $PlasmaPulse -TimeoutSeconds 120 @common
        if ($held.phase -ne 'result' -or $held.pid -ne $gamePid -or $held.depth -ne $Plan.depth -or
            $held.room -ne $regions[$Plan.depth].room -or $held.heldResultRound -ne 1 -or
            $held.frame -le $State.frame -or $held.oxygen -le 0 -or !$held.nativeSave.sha256 -or
            $null -eq $held.nativeSave.wallet[$currency] -or
            $held.nativeSave.wallet[$currency] -lt $before.wallet[$currency] -or
            $held.nativeSave.catchPipeline.inventories.Count -ne 5) {
            throw 'The original resource expedition did not verify its held material and catch inventories.'
        }

        $landed = & $session -Action FinishResult -Depth $Plan.depth -ResultVerified -TimeoutSeconds 45 @common
        if ($landed.pid -ne $gamePid -or $landed.room -ne 'rm_main_island' -or $landed.frame -le $held.frame -or
            !$landed.nativeSaveBefore.sha256 -or !$landed.nativeSaveAfter.sha256 -or
            $landed.nativeSaveBefore.wallet[$currency] -ne $held.nativeSave.wallet[$currency] -or
            $landed.nativeSaveAfter.wallet[$currency] -ne $held.nativeSave.wallet[$currency]) {
            throw 'The original Finish result did not preserve the material balance on the same island.'
        }
        try {
            $State = Get-IslandStatus
        } catch {
            if ($_.Exception.Message -ne 'Progression requires the resident Shelldiver game on its settled island.') { throw }
            $State = Wait-ProgressionIsland 'the material expedition'
        }
        $after = $State.nativeSave
        $routing = Compare-NativeCatchPipeline $held.nativeSave $after
        if ($State.frame -lt $landed.frame -or !$after.sha256 -or $after.catchPipeline.inventories.Count -ne 5 -or
            !$routing -or $after.wallet[$currency] -ne $held.nativeSave.wallet[$currency]) {
            throw 'The settled island save did not verify the material balance and original five-inventory catch flow.'
        }

        $walletDelta = [ordered]@{}
        foreach ($key in $walletFields.Keys) {
            $walletDelta[$key] = [decimal]$after.wallet[$key] - [decimal]$before.wallet[$key]
        }
        $rounds.Add([pscustomobject]@{
            round=$round; depth=$Plan.depth; returnedFrame=$landed.frame; nativeWalletDelta=$walletDelta;
            nativeBalanceVerified=$true; nativeOxygenLoss=$false; settlementPerformed=$false;
            automaticCatchRouting=$routing; heldResult=$held; islandSaveHash=$after.sha256
        })
        if ($after.wallet[$currency] - $baseline.wallet[$currency] -ge $Plan.shortfallToNextRank) { break }
    }
    return [pscustomobject]@{
        phase='landed'; pid=$State.pid; room=$State.room; kind='Resource'; depth=$Plan.depth;
        saveBefore=$baseline; verifiedSaveAfter=$State.nativeSave; rounds=$rounds.ToArray();
        roundsCompleted=$rounds.Count; roundLimit=$Plan.rounds; nativeBalanceVerified=$rounds.Count -gt 0;
        shopPayoutDeferred=$true
    }
}

function Get-RevenuePlan($Saved, [int]$FishDepth, [int]$MineDepth, [bool]$NeedsObsidian, [string]$Purpose) {
    $key = "conversion-$FishDepth"
    $hasCross = $Saved.ranks.o_skill_transmutator_sell -ge 1 -or $Saved.ranks.o_skill_store_transmutate -ge 1
    if ($Saved.ranks.o_skill_jellyfish_transmutator -ge 1 -and
        $Saved.ranks.o_skill_transmutator_auto_output -ge 1 -and
        (!$hasCross -or (Test-ProgressionCrossAutomation)) -and
        $failures[$key] -lt 2 -and [IO.File]::Exists($conversion)) {
        return @{ kind='Conversion'; key=$key; fishingDepth=$FishDepth; depth=$MineDepth;
            miningRounds=if ($NeedsObsidian) { $MiningRounds } else { 1 }; purpose=$Purpose }
    }
    if (Test-ProgressionGoldenOutput $Saved) {
        return @{kind='CatchForGold';key="golden-fish-$FishDepth";depth=$FishDepth;purpose=$Purpose}
    }
    return @{ kind='Fish'; key="fish-$FishDepth"; depth=$FishDepth; purpose=$Purpose }
}

function Get-ProgressionPlan($Saved, $State) {
    if ($Saved.finished -and $Saved.ranks.o_skill_hammock -ge 1) { return @{ kind='Complete' } }
    if ($Saved.alchemyPending) { return @{ kind='Alchemy'; key='alchemy'; count=1; resume=$true } }
    $missingFinals = @($finals | Where-Object { [int]$Saved.ranks[$_] -lt 1 })
    if (!$missingFinals.Count -and ($Saved.ranks.o_skill_hammock -ge 1 -or $Saved.wallet.shells -ge $hammockPrice)) {
        return @{ kind='End'; key='end' }
    }
    if ($State.nativeSave.playerJellyfish -gt 0 -or $State.nativeSave.submarineJellyfish -gt 0 -or
        $State.nativeSave.storeQueuedJellyfish -gt 0 -or $State.nativeSave.storeShellCoins -gt 0) {
        return @{ kind='Settle'; key='settle' }
    }

    $required = [ordered]@{}
    $unpriced = [Collections.Generic.HashSet[string]]::new()
    foreach ($id in $missingFinals) { Add-ProgressionRequirement $id 1 $Saved $required $unpriced }
    $need = [ordered]@{}
    foreach ($currency in $walletFields.Keys) { $need[$currency] = [decimal]0 }
    foreach ($id in $required.Keys) {
        $node = $catalog[$id]
        if ($node.status -ne 'constant') { continue }
        $missingRanks = $node.ranks | Where-Object { $_.rank -gt [int]$Saved.ranks[$id] -and $_.rank -le $required[$id] }
        foreach ($price in $missingRanks) { $need[$price.currency] += [decimal]$price.price }
    }

    $redRoute = $FishingDepth -eq 1200 -and $Saved.rank -ge $regions[1200].requiredRanks
    $priorityVialSkill = if ($redRoute -and $Saved.ranks.o_skill_shock_resistance_10 -lt 1) { 'o_skill_shock_resistance_10' }
        elseif ($redRoute -and $Saved.ranks.o_skill_bubble_damage_10 -lt 1) { 'o_skill_bubble_damage_10' }
        elseif ($redRoute -and $Saved.ranks.o_skill_transmutator_golden -ge 1 -and
            $Saved.ranks.o_skill_plasma_damage_08 -ge $catalog.o_skill_plasma_damage_08.maxRank -and
            $Saved.ranks.o_skill_plasma_damage_10 -lt 1) { 'o_skill_plasma_damage_10' }
    $priorityPurpose = switch ($priorityVialSkill) {
        'o_skill_shock_resistance_10' { 'Shock Resistance II' }
        'o_skill_bubble_damage_10' { 'Bubble Damage X' }
        'o_skill_plasma_damage_10' { 'Plasma Damage X' }
    }
    $stationUnlocked = $Saved.ranks.o_skill_alchemy_station -ge 1
    $priorityPrice = if ($priorityVialSkill) { $catalog[$priorityVialSkill].ranks[0] }
    $shellReserve = if ($priorityVialSkill -and $Saved.wallet.lifeVials -lt 1) { $exchangePrice } else { [decimal]0 }
    $shellBudget = [decimal]::Floor([Math]::Max([decimal]0,$Saved.wallet.shells-$shellReserve) / $exchangePrice)
    if ($priorityPrice -and $priorityPrice.rank -eq 1 -and $priorityPrice.currency -eq 'lifeVials' -and
        $priorityPrice.price -eq 1 -and (Test-ProgressionPrerequisites $catalog[$priorityVialSkill] $Saved.ranks)) {
        if ($Saved.wallet.lifeVials -ge 1) {
            return @{ kind='Upgrade'; key='upgrade'; purpose=$priorityPurpose;
                purchases=@(@{id=$priorityVialSkill;rank=1;currency='lifeVials';price=[decimal]1}) }
        }
        if ($stationUnlocked -and $Saved.wallet.shells -ge $exchangePrice) {
            return @{ kind='Alchemy'; key='alchemy'; count=1; purpose=$priorityPurpose }
        }
    }

    $firstResistance = !$redRoute -and $Saved.ranks.o_skill_shock_frequency -ge 1 -and $Saved.ranks.o_skill_shock_resistance_10 -lt 1
    $firstGolden = !$priorityVialSkill -and $Saved.ranks.o_skill_transmutator_slots_02 -ge 1 -and $Saved.ranks.o_skill_transmutator_golden -lt 1
    $earlyVials = [int]$firstResistance + 4*[int]$firstGolden + [int][bool]$priorityVialSkill
    $priorVials = if ($firstResistance) { 1 } elseif ($firstGolden) { 4 } else { 0 }
    if ($stationUnlocked -and $priorVials -gt $Saved.wallet.lifeVials -and $shellBudget -ge 1) {
        $count = [int][Math]::Min([decimal]$MaxExchanges,[Math]::Min($shellBudget,[decimal]($priorVials-$Saved.wallet.lifeVials)))
        return @{ kind='Alchemy'; key='alchemy'; count=$count; purpose=if ($firstResistance) { 'Shock Resistance II' } else { 'Golden transmutator' } }
    }

    $endgameGearReady = $redRoute -and !$priorityVialSkill -and
        $Saved.ranks.o_skill_transmutator_golden -ge 1 -and $Saved.ranks.o_skill_plasma_damage_10 -ge 1
    $obsidianReserve = if ($endgameGearReady) { $need.obsidian } else { [decimal]0 }
    $eligible = [ordered]@{}
    if ($endgameGearReady) {
        foreach ($id in $magmaThroughputTargets.Keys) { $eligible[$id] = $magmaThroughputTargets[$id] }
    }
    if ($redRoute) {
        foreach ($id in $redWeaponTargets.Keys) { $eligible[$id] = $redWeaponTargets[$id] }
    }
    foreach ($id in $support.Keys) {
        if ($id -like '*transmutator*' -and ($Saved.ranks.o_skill_transmutator_sell -ge 1 -or $Saved.ranks.o_skill_store_transmutate -ge 1)) { continue }
        $eligible[$id] = $support[$id]
    }
    foreach ($id in $required.Keys) { $eligible[$id] = [Math]::Max([int]$eligible[$id],[int]$required[$id]) }
    $budget = [ordered]@{}
    foreach ($currency in $walletFields.Keys) { $budget[$currency] = $Saved.wallet[$currency] }
    $purchases = [Collections.Generic.List[object]]::new()
    $projectedRanks = @{} + $Saved.ranks
    foreach ($id in $eligible.Keys) {
        if ($priorityVialSkill -and $id -in 'o_skill_transmutator_golden',$priorityVialSkill) { continue }
        $node = $catalog[$id]
        if ($node.status -ne 'constant' -or !(Test-ProgressionPrerequisites $node $projectedRanks)) { continue }
        for ($level = [int]$Saved.ranks[$id] + 1; $level -le $eligible[$id] -and $purchases.Count -lt $MaxPurchases; ++$level) {
            $price = $node.ranks[$level-1]
            if (!$price -or $price.rank -ne $level -or $budget[$price.currency] -lt [decimal]$price.price) { break }
            if ($price.currency -eq 'shells' -and $shellReserve -gt 0 -and
                $id -notin 'o_skill_shock_frequency','o_skill_shock_resistance_01','o_skill_alchemy_station' -and
                $budget.shells - [decimal]$price.price -lt $shellReserve) { break }
            if ($price.currency -eq 'obsidian' -and $level -gt [int]$required[$id] -and
                $budget.obsidian - [decimal]$price.price -lt $obsidianReserve) { break }
            if ($price.currency -eq 'lifeVials') {
                $reserve = switch ($id) {
                    'o_skill_shock_resistance_10' { 0 }
                    'o_skill_transmutator_golden' { [int]$firstResistance }
                    default { $earlyVials }
                }
                if ($budget.lifeVials - [decimal]$price.price -lt $reserve) { break }
            }
            $budget[$price.currency] -= [decimal]$price.price
            if ($price.currency -eq 'obsidian' -and $level -le [int]$required[$id]) {
                $obsidianReserve = [Math]::Max([decimal]0,$obsidianReserve-[decimal]$price.price)
            }
            $purchases.Add(@{ id=$id; rank=$level; currency=$price.currency; price=[decimal]$price.price })
            $projectedRanks[$id] = $level
        }
    }
    if ($purchases.Count) { return @{ kind='Upgrade'; key='upgrade'; purchases=$purchases.ToArray() } }

    $fishDepth = if ($FishingDepth -eq 1200 -and $Saved.rank -ge $regions[1200].requiredRanks) { 1200 } else { 1100 }
    if ($Saved.rank -lt $regions[$fishDepth].requiredRanks) { return @{ kind='Unlock'; key='unlock'; rank=$regions[$fishDepth].requiredRanks } }
    if ($Saved.ranks.o_skill_submarine_recover -lt 1) {
        return @{ kind='Blocked'; reason='The native full-backpack fishing route needs Submarine Recover I.' }
    }
    $mining = if ($MiningDepth) { $MiningDepth } elseif ($fishDepth -eq 1200 -and $State.oxygenMax -ge 1150000) { 1200 } else { 1000 }
    if ($Saved.rank -lt $regions[$mining].requiredRanks) { $mining = 1000 }
    if ($failures["resource-obsidian-$mining"] -ge 2 -and $mining -eq 1200) { $mining = 1000 }


    if ($priorityVialSkill -and $Saved.wallet.lifeVials -lt 1 -and $Saved.wallet.shells -lt $exchangePrice -and $stationUnlocked) {
        return Get-RevenuePlan $Saved $fishDepth $mining ($priorityVialSkill -eq 'o_skill_bubble_damage_10') "one vial for $priorityPurpose"
    }
    $maxChance = $Saved.ranks.o_skill_alchemy_station_dc_01 -ge 5 -and $Saved.ranks.o_skill_alchemy_station_dc_02 -ge 5
    $missingVials = [Math]::Max(0,[int]($need.lifeVials-$Saved.wallet.lifeVials))
    $missingObsidian = $Saved.wallet.obsidian -lt $need.obsidian
    if ($stationUnlocked -and $shellBudget -ge 1 -and $maxChance -and $missingVials -gt 0) {
        $count = [int][Math]::Min([decimal]$MaxExchanges,[Math]::Min($shellBudget,[decimal]$missingVials))
        return @{ kind='Alchemy'; key='alchemy'; count=$count }
    }
    if ($priorVials -gt $Saved.wallet.lifeVials -and $stationUnlocked -and $shellBudget -lt 1) {
        $purpose = if ($firstResistance) { 'first Shock Resistance II vial' } else { 'four vials for Golden transmutator' }
        return Get-RevenuePlan $Saved $fishDepth $mining $missingObsidian $purpose
    }
    if ($missingObsidian -and $Saved.wallet.shells -lt $hammockPrice -and ($completed + $recoveredMining) % 3 -eq 0) {
        $next = Get-RevenuePlan $Saved $fishDepth $mining $true 'native conversion and obsidian'
        if ($next.kind -eq 'Conversion') { return $next }
    }
    foreach ($currency in 'obsidian','crystals','mushrooms','scrap') {
        if ($Saved.wallet[$currency] -ge $need[$currency]) { continue }
        $depth = switch ($currency) { 'obsidian' {$mining}; 'crystals' {500}; 'mushrooms' {900}; 'scrap' {300} }
        if ($failures["resource-$currency-$depth"] -ge 2 -and $currency -ne 'obsidian') {
            $depth = switch ($currency) { 'crystals' {600}; 'mushrooms' {800}; 'scrap' {200} }
        }
        $sector = if ($currency -eq 'obsidian' -and $depth -eq 1000 -and $failures['resource-obsidian-1000'] -ge 2) { 'East' } else { 'West' }
        return @{ kind='Resource'; key="resource-$currency-$depth"; depth=$depth; currency=$currency; sector=$sector }
    }
    if ($unpriced.Count -and !$need.shells -and !$missingVials) {
        return @{ kind='Blocked'; reason='Missing verified native prices for required skills.'; skills=@($unpriced) }
    }
    if ($missingVials -gt 0 -and $Saved.ranks.o_skill_alchemy_station -lt 1) {
        if ($Saved.wallet.shells -ge 1000000000000) {
            return @{ kind='Blocked'; reason='The unmet native prerequisites for the Alchemy Station must be unlocked before exchanging.' }
        }
        return Get-RevenuePlan $Saved $fishDepth $mining $missingObsidian 'native Alchemy Station unlock'
    }
    if ($missingVials -gt 0 -and $shellBudget -ge 1) {
        return @{ kind='Alchemy'; key='alchemy'; count=[int][Math]::Min([decimal]$MaxExchanges,[Math]::Min($shellBudget,[decimal]$missingVials)) }
    }
    if ($missingFinals.Count -and $Saved.wallet.shells -ge $hammockPrice -and
        $Saved.wallet.shells -ge $need.shells -and !$missingVials) {
        return @{ kind='Blocked'; reason='No verified stock purchase advances the remaining final skills.'; skills=$missingFinals }
    }
    return Get-RevenuePlan $Saved $fishDepth $mining $missingObsidian 'shells for native final objectives'
}

function Read-MaxRankCatalog([switch]$Live) {
    if ($Live) {
        $ack = & $control -Action skills -Mailbox $Mailbox -TimeoutSeconds 5
        $data = $ack.data | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json -AsHashtable
        $wait = [Diagnostics.Stopwatch]::StartNew()
        do {
            $sample = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds 3
            if ($sample.pid -ne $gamePid -or $sample.room -ne 'rm_main_island' -or $sample.flags.transitioning -or
                $sample.activeInputFrames -ne 0 -or $sample.guiPointer.active) {
                throw 'The native skill price read did not match a settled island in the resident process.'
            }
            if ($sample.frame -ge $ack.frame) { break }
            Start-Sleep -Milliseconds 35
        } while ($wait.Elapsed.TotalSeconds -lt 2)
        if ($sample.frame -lt $ack.frame) { throw 'The original skill price acknowledgement has no fresh matching snapshot.' }
    } else {
        $data = [IO.File]::ReadAllText($NativeCatalogReceipt) | ConvertFrom-Json -AsHashtable
    }
    if ($data.truncated -or $data.nodes.Count -ne 241 -or $catalog.Count -ne 241 -or $data.all_skill_levels -ne 800) {
        throw 'The original resident skill catalog does not prove 241 nodes and 800 levels.'
    }
    $nativeCurrencies = @{ 0='shells'; 2='shells'; 3='scrap'; 4='crystals'; 5='mushrooms'; 6='obsidian'; 7='lifeVials' }
    $nodes = [ordered]@{}
    $total = 0
    $rankSum = 0
    foreach ($id in $catalog.Keys) {
        $original = $catalog[$id]
        $native = $data.nodes[$id]
        $stockMax = switch ($original.status) {
            'constant' { $original.maxRank }
            'variant' { $original.baseRanks.Count }
            'unsupported' { if ($id -in 'o_skill_submarine','o_skill_hammock') { 1 } }
        }
        if (!$stockMax -or $native.maxRank -ne $stockMax -or @($native.prices).Count -ne $stockMax -or
            $null -eq $native.rank -or $native.rank -lt 0 -or $native.rank -gt $stockMax) {
            throw "The original maximum or native price table could not be verified for $id."
        }
        $minimum = @($original.needsAnyLevel)
        $maximum = @($original.needsMaxLevel)
        if (!$native.needsMaxLevel.Count -and $native.needsAnyLevel.Count -eq $minimum.Count + $maximum.Count) {
            $minimum += $maximum
            $maximum = @()
        } elseif ($native.needsMaxLevel.Count -ne $maximum.Count -or $native.needsAnyLevel.Count -ne $minimum.Count) {
            throw "The original named prerequisites did not match the resident skill graph for $id."
        }
        $prices = for ($i = 0; $i -lt $stockMax; ++$i) {
            $type = if ($native.currency -is [array]) { $native.currency[$i] } else { $native.currency }
            $coin = if ($null -ne $type) { $nativeCurrencies[[int]$type] }
            $price = $native.prices[$i]
            if (!$coin -or $null -eq $price -or $price -lt 0 -or ([int]$type -eq 0 -and $price -ne 0)) {
                throw "The native currency or price could not be verified for $id rank $($i+1)."
            }
            @{ id=$id; rank=$i+1; currency=$coin; price=[decimal]$price }
        }
        $nodes[$id] = @{
            maxRank=[int]$stockMax; nativeRank=[int]$native.rank; unlocked=[bool]$native.unlocked
            x=[double]$original.x; y=[double]$original.y; needsAnyLevel=$minimum; needsMaxLevel=$maximum
            prices=@($prices); source=$original.status
        }
        $total += $stockMax
        $rankSum += $native.rank
    }
    if ($total -ne 800 -or $rankSum -ne $data.total_skill_levels_upgraded) {
        throw 'The original native skill level totals do not reconcile.'
    }
    return @{ nodes=$nodes; total=$total; reportedRank=$rankSum; prestige=$data.prestige_level; live=[bool]$Live }
}

function Get-MaxRankAudit($Saved, $Proof) {
    $remaining = [ordered]@{}
    $costs = [ordered]@{}
    $counts = [ordered]@{}
    foreach ($currency in $walletFields.Keys) { $costs[$currency]=[decimal]0; $counts[$currency]=0 }
    foreach ($id in $Saved.ranks.Keys) {
        if ([int]$Saved.ranks[$id] -ne 0 -and !$Proof.nodes.Contains($id)) {
            throw "The original save contains a rank outside the 241 verified nodes: $id."
        }
    }
    $knownRank = 0
    foreach ($id in $Proof.nodes.Keys) {
        $node = $Proof.nodes[$id]
        $have = [int]$Saved.ranks[$id]
        if ($have -lt 0 -or $have -gt $node.maxRank) { throw "Saved rank $have is outside the original maximum for $id." }
        $knownRank += $have
        if ($have -eq $node.maxRank) { continue }
        $prices = @($node.prices | Where-Object rank -gt $have)
        $remaining[$id] = @{ rank=$have; maxRank=$node.maxRank; prices=$prices; source=$node.source }
        foreach ($price in $prices) {
            $costs[$price.currency] += $price.price
            ++$counts[$price.currency]
        }
    }
    if ($Saved.rank -ne $knownRank) { throw 'The saved rank total and original node ranks do not match.' }
    $deficits = [ordered]@{}
    foreach ($currency in $walletFields.Keys) {
        $deficits[$currency] = [Math]::Max([decimal]0,$costs[$currency]-$Saved.wallet[$currency])
    }
    return [ordered]@{
        target=$Proof.total; rank=$knownRank; missingRanks=$Proof.total-$knownRank; completeNodes=$Proof.nodes.Count-$remaining.Count
        missingNodes=$remaining; ranksByCurrency=$counts; remainingCosts=$costs; shortages=$deficits
        nativeCatalogRank=$Proof.reportedRank; livePrices=$Proof.live; prestige=$Proof.prestige
    }
}

function Test-MaxRankPrerequisites($Node, $Ranks) {
    foreach ($parent in $Node.needsAnyLevel) {
        if ([int]$Ranks[$parent] -lt 1) { return $false }
    }
    foreach ($parent in $Node.needsMaxLevel) {
        if ([int]$Ranks[$parent] -lt $maxRankProof.nodes[$parent].maxRank) { return $false }
    }
    return $true
}

function Get-MaxRankCoreVialPurchase($Ranks) {
    foreach ($id in $maxRankCoreVials) {
        $node = $maxRankProof.nodes[$id]
        $rank = [int]$Ranks[$id]
        if ($rank -lt $node.maxRank -and (Test-MaxRankPrerequisites $node $Ranks) -and $node.prices[$rank].currency -eq 'lifeVials') {
            return $node.prices[$rank]
        }
    }
}

function Get-MaxRankPurchases($Saved, $Audit) {
    $ranks = @{} + $Saved.ranks
    $wallet = @{} + $Saved.wallet
    $orders = [Collections.Generic.List[object]]::new()
    $position = if ($script:maxRankLastNode) { $script:maxRankLastNode } else { $maxRankProof.nodes.o_skill_hammock }
    $terminal = @('o_skill_hammock')
    if (($maxRankCrossPerks | Where-Object { $_ -in $Audit.missingNodes.Keys }) -and
        ($Saved.ranks.o_skill_transmutator_auto_output -lt 1 -or !(Test-ProgressionCrossAutomation))) {
        $terminal += $maxRankCrossPerks
    }
    $normal = @($Audit.missingNodes.Keys | Where-Object { $_ -notin $terminal })
    $ids = if ($normal.Count) { $normal }
        elseif ($Audit.missingNodes.o_skill_hammock) { 'o_skill_hammock' }
        else { @($terminal | Where-Object { $_ -in $Audit.missingNodes.Keys }) }
    $unlocksOnFirst = @{}
    $unlocksOnMax = @{}
    foreach ($id in $Audit.missingNodes.Keys) {
        $node = $maxRankProof.nodes[$id]
        foreach ($parent in $node.needsAnyLevel) { ++$unlocksOnFirst[$parent] }
        foreach ($parent in $node.needsMaxLevel) { ++$unlocksOnMax[$parent] }
    }
    while ($orders.Count -lt $MaxPurchases) {
        $choices = foreach ($id in $ids) {
            $node = $maxRankProof.nodes[$id]
            $rank = [int]$ranks[$id]
            if ($rank -ge $node.maxRank -or !(Test-MaxRankPrerequisites $node $ranks)) { continue }
            $price = $node.prices[$rank]
            if ($wallet[$price.currency] -lt $price.price) { continue }
            $priority = [Array]::IndexOf($maxRankPriority,$id)
            if ($priority -lt 0) { $priority = $maxRankPriority.Count }
            $distance = [Math]::Abs($node.x-$position.x)+[Math]::Abs($node.y-$position.y)
            $unlocks = if ($rank -eq 0) { [int]$unlocksOnFirst[$id] } else { 0 }
            if ($price.rank -eq $node.maxRank) { $unlocks += [int]$unlocksOnMax[$id] }
            @{ id=$id; node=$node; price=$price; priority=$priority; fieldBenefit=[int]$maxRankFieldBenefit[$id]
                unlocks=$unlocks; distance=$distance }
        }
        # First find the cheapest remaining rank within each currency, then order the independent baskets.
        $cheapest = @($choices | Group-Object { $_.price.currency } | ForEach-Object {
            $_.Group | Sort-Object -Property { $_.price.price },{ $_.priority },{ -$_.fieldBenefit },
                { -$_.unlocks },{ $_.distance },{ $_.id } | Select-Object -First 1
        })
        $choice = $cheapest | Sort-Object -Property { $_.priority },{ -$_.fieldBenefit },{ -$_.unlocks },{ $_.distance },{ $_.id } |
            Select-Object -First 1
        if (!$choice) { break }
        $position = $choice.node
        $price = $choice.price
        $wallet[$price.currency] -= $price.price
        $ranks[$choice.id] = $price.rank
        $orders.Add($price)
    }
    return $orders.ToArray()
}

function Get-MaxRankRedDeparture($NativeSave) {
    $slotCapacity = $NativeSave.playerJellyfishSlotCapacity
    $compatible = $NativeSave.playerRedJellyfishCompatibleSpace
    $carried = $NativeSave.playerJellyfish
    return @{
        speciesId=11; rarity=0; compatibleSpace=$compatible; slotCapacity=$slotCapacity; carried=$carried
        ready=($carried -eq 0 -or ($slotCapacity -gt 0 -and $compatible -ge $slotCapacity))
    }
}

function Test-ProgressionGoldTail($NativeSave) {
    $player = $NativeSave.catchPipeline.inventories.player_inventory
    return ($player.count -gt 0 -and $NativeSave.playerTransmutable -eq 0 -and $player.typed.Count -gt 0 -and
        !($player.typed.Keys | Where-Object { [int]($_.Split(',')[1]) -ne 2 }))
}

function Invoke-ProgressionGoldTailSale {
    $island = Join-Path $ControllerRoot 'Invoke-ShelldiverIsland.ps1'
    . (Join-Path $ControllerRoot 'ShelldiverCatchFlow.ps1')
    $lock = Join-Path $Mailbox 'session.lock'
    $lease = [IO.File]::Open($lock,'OpenOrCreate','ReadWrite','None')
    try {
        $start = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds 3
        if ($start.pid -ne $gamePid -or $start.room -ne 'rm_main_island' -or $null -eq $start.scene.shop.x -or
            !$start.inputReady -or $start.flags.transitioning -or $start.flags.pause -or $start.flags.player_inventory_open -or
            $start.activeInputFrames -ne 0 -or $start.guiPointer.active -or $start.scene.player.can_use_tool -ne 1) {
            throw 'The original island shop was unavailable for the Golden stack.'
        }
        $checkpoint = & $island -Action Move -X $start.scene.shop.x -Mailbox $Mailbox -TimeoutSeconds 12
        if ($checkpoint.pid -ne $gamePid -or $checkpoint.room -ne 'rm_main_island' -or !$checkpoint.frame -or
            $null -eq $checkpoint.scene.player.x -or [Math]::Abs($checkpoint.scene.player.x-$start.scene.shop.x) -gt 12) {
            throw 'The resident diver did not reach the original island shop.'
        }
        $state = & $session -Action Status @common
        $before = $state.nativeSave
        if ($state.pid -ne $gamePid -or $state.room -ne 'rm_main_island' -or !$state.inputReady -or
            $state.frame -lt $checkpoint.frame -or $state.canUseTool -ne 1 -or $state.virtualPointerActive -or
            $state.activeInputFrames -ne 0 -or !$before.sha256 -or $before.catchPipeline.inventories.Count -ne 5) {
            throw 'The original Golden stack sale lost its native position or saved inventory proof.'
        }
        if (!(Test-ProgressionGoldTail $before) -or $before.storeCompatibleJellyfishSpace -le 0) {
            return @{phase='unavailable';pid=$gamePid;before=$before;reason='No pure Golden backpack or compatible shop space remained before the pulse'}
        }

        $pulse = & $island -Action Interact -Frames 90 -Mailbox $Mailbox -TimeoutSeconds 8
        if ($pulse.pid -ne $gamePid -or $pulse.room -ne 'rm_main_island' -or $pulse.frame -le $checkpoint.frame) {
            throw 'The original shop pulse did not confirm a fresh resident island frame.'
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $observed = & $session -Action Status @common
            if ($observed.pid -ne $gamePid -or $observed.room -ne 'rm_main_island' -or
                !$observed.inputReady -or $observed.canUseTool -ne 1) {
                throw 'The resident island changed during the original Golden stack sale.'
            }
            $after = $observed.nativeSave
            $routed = $null
            if ($after.sha256 -and $after.sha256 -ne $before.sha256 -and $after.catchPipeline.inventories.Count -eq 5 -and
                $observed.frame -ge $pulse.frame -and $observed.activeInputFrames -eq 0 -and !$observed.virtualPointerActive -and
                $after.playerJellyfish -lt $before.playerJellyfish -and $after.submarineJellyfish -le $before.submarineJellyfish) {
                $routed = Compare-NativeCatchPipeline $before $after
            }
            if ($routed -and ($routed.stageDeltas.store_inventory -gt 0 -or $routed.creditedShells -gt 0)) {
                return @{phase='queued';pid=$gamePid;frame=$observed.frame;before=$before;after=$after;
                    queuedFromBackpack=$before.playerJellyfish-$after.playerJellyfish;automaticCatchRouting=$routed;
                    departure=Get-MaxRankRedDeparture $after}
            }
            Start-Sleep -Milliseconds 120
        } while ($timer.Elapsed.TotalSeconds -lt 4)
        throw 'The original shop pulse was acknowledged, but the saved Golden stack movement could not be verified.'
    } finally {
        $lease.Dispose()
    }
}

function Get-MaxRankPlan($Saved, $State, $Audit) {
    if (!$Audit.missingRanks) { return @{kind='Complete'; target=800;requiresResidentVerification=$true} }
    if ($Saved.alchemyPending) { return @{kind='Alchemy';key='alchemy';count=1;resume=$true;purpose='Collect the funded native exchange'} }
    $purchases = @(Get-MaxRankPurchases $Saved $Audit)
    if ($purchases.Count) { return @{kind='Upgrade';key='upgrade';purchases=$purchases} }

    $needed = $Audit.shortages
    $coreVial = Get-MaxRankCoreVialPurchase $Saved.ranks
    $chance1 = [int]$Saved.ranks.o_skill_alchemy_station_dc_01
    $chance2 = [int]$Saved.ranks.o_skill_alchemy_station_dc_02
    # Original Alchemy passes 4 and 12 percentage points per rank to get_chance and produces at most two.
    $extraVialChance = [decimal](4*$chance1+12*$chance2)/100
    $expectedYield = [decimal]1+$extraVialChance
    $doubleChanceMaxed = $chance1 -ge $maxRankProof.nodes.o_skill_alchemy_station_dc_01.maxRank -and
        $chance2 -ge $maxRankProof.nodes.o_skill_alchemy_station_dc_02.maxRank
    $needsObsidian = $needed.obsidian -gt 0
    $expectedExchangeCount = [decimal]::Ceiling($needed.lifeVials/$expectedYield)
    $immediateShellReserve = $Audit.remainingCosts.shells
    if ($Audit.missingNodes.o_skill_hammock) {
        $immediateShellReserve -= $maxRankProof.nodes.o_skill_hammock.prices[0].price
    }
    $finance = @{
        nativeExtraVialChance=$extraVialChance; expectedVialsPerExchange=$expectedYield
        remainingVialShortage=$needed.lifeVials; estimatedRemainingExchangeShells=$exchangePrice*$expectedExchangeCount
        remainingSkillShells=$Audit.remainingCosts.shells; nearTermSkillShellReserve=$immediateShellReserve
    }
    $spendableShells = [Math]::Max([decimal]0,$Saved.wallet.shells-$immediateShellReserve)
    $exchangeBudget = [decimal]::Floor($spendableShells/$exchangePrice)
    $readyVialTarget = if ($coreVial) { [decimal]$coreVial.price } else { [decimal]0 }
    $vialBuffer = [Math]::Min($Audit.remainingCosts.lifeVials,[decimal]$MaxExchanges)
    $targetVials = if ($doubleChanceMaxed -or !$needsObsidian) { $Audit.remainingCosts.lifeVials }
        else { [Math]::Max($readyVialTarget,$vialBuffer) }
    $desiredVials = [Math]::Max([decimal]0,$targetVials-$Saved.wallet.lifeVials)
    if ($desiredVials -gt 0 -and $exchangeBudget -ge 1 -and $Saved.ranks.o_skill_alchemy_station -ge 1) {
        $count = [int][Math]::Min([decimal]$MaxExchanges,[Math]::Min($exchangeBudget,[decimal]::Ceiling($desiredVials/$expectedYield)))
        return @{kind='Alchemy';key='alchemy';count=$count;finance=$finance;
            purpose=if ($coreVial) { "Fund the next native vial upgrade $($coreVial.id)" } else { 'Build the native vial balance while further ore is needed' }}
    }

    $shop = $State.nativeSave
    $pendingShells = [decimal]$shop.storeShellCoins
    $marketBusy = $shop.storeQueuedJellyfish -gt 0 -or $shop.transmutatorInputJellyfish -gt 0 -or $shop.transmutatorOutputJellyfish -gt 0
    $carrying = $shop.playerJellyfish -gt 0 -or $shop.submarineJellyfish -gt 0
    $canDeferGoldenBacklog = $State.supportsDeferredResourceBacklog -eq $true -and $shop.storageAutoOutput -eq $true -and
        $shop.transmutatorAutoOutput -eq $true -and $shop.transmutatorOutputType -eq 2
    $departure = Get-MaxRankRedDeparture $shop
    $marketWait = $null
    $goldenCarry = $shop.playerTransmutable -gt 0 -and (Test-ProgressionGoldenOutput $Saved)
    if ($goldenCarry) {
        $station = & $transmutator -Action Status -TimeoutSeconds 8 -ControllerRoot $ControllerRoot @common
        if ($station.phase -eq 'status' -and $station.outputType -eq 2 -and !$station.unsupportedSkills.Count -and
            $station.inputCanAcceptBackpack -eq $true) {
            $fit = $station.queues.backpackFit
            return @{kind='ConvertCatch';key='golden-convert-catch';
                transferAction=if ($fit) {
                    if ($marketBusy -or !$fit.canFitAll) { 'TransferReady' } else { 'TransferAll' }
                } elseif ($marketBusy) { 'Transfer' } else { 'TransferAll' };
                inputFit=$fit;purpose='Queue eligible backpack catch for native Golden transmutation'}
        }
    }

    $shellTarget = $Audit.remainingCosts.shells + $finance.estimatedRemainingExchangeShells
    $needsShells = $Saved.wallet.shells -lt $shellTarget
    $creditEnablesPurchase = $false
    if ($pendingShells -gt 0 -and $Audit.remainingCosts.shells -gt 0) {
        $creditedWallet = @{} + $Saved.wallet
        $creditedWallet.shells += $pendingShells
        $creditEnablesPurchase = [bool](Get-MaxRankPurchases @{ranks=$Saved.ranks;wallet=$creditedWallet} $Audit |
            Where-Object currency -eq 'shells' | Select-Object -First 1)
    }
    $creditEnablesExchange = $desiredVials -gt 0 -and !$exchangeBudget -and $Saved.ranks.o_skill_alchemy_station -ge 1 -and
        $spendableShells+$pendingShells -ge $exchangePrice
    if ($script:unconfirmedShopCredit -and $Saved.wallet.shells -gt $script:unconfirmedShopCredit.beforeShells) {
        $script:unconfirmedShopCredit = $null
    }
    if ($pendingShells -gt 0 -and ($creditEnablesPurchase -or $creditEnablesExchange -or (!$marketBusy -and !$carrying))) {
        if ($script:unconfirmedShopCredit) {
            return @{kind='WaitMarket';key='market-native-save';purpose='Wait for the acknowledged native chest credit to appear in the original save'}
        }
        if ($State.supportsCollectShopCredit -eq $true) {
            return @{kind='CollectShopCredit';key='shop-credit';finance=$finance;
                purpose='Use already earned native shells without waiting for the remaining catch'}
        }
        if (!$marketBusy -and !$carrying) { return @{kind='Settle';key='settle'} }
    }
    if ($carrying) {
        $automatedCarry = $goldenCarry -or ($shop.storageAutoOutput -and $shop.submarineTransmutable -gt 0)
        if ($canDeferGoldenBacklog -and $needsObsidian -and $Saved.rank -ge $regions[1200].requiredRanks -and $departure.ready) {
            return @{kind='Resource';key='resource-obsidian-1200';depth=1200;currency='obsidian';sector='West';
                purpose='Mine obsidian while the native Golden catch remains queued';finance=$finance;
                departure=$departure;deferShopPayout=$true}
        }
        if ($canDeferGoldenBacklog -and !$departure.ready -and (Test-ProgressionGoldTail $shop) -and
            $shop.storeCompatibleJellyfishSpace -gt 0) {
            return @{kind='QueueGoldTail';key='queue-gold-tail';departure=$departure;
                purpose='Queue the saved Golden backpack fish in one original shop interaction to free ordinary Red slots'}
        }
        if (!$automatedCarry -and (!$canDeferGoldenBacklog -or !(Test-ProgressionGoldTail $shop))) {
            return @{kind='Settle';key='settle';deferShopPayout=$marketBusy}
        }
        $marketWait = @{kind='WaitMarket';key='market-catch-space';departure=$departure;
            purpose='Wait for the original transmutator or shop to make space for the backpack'}
    }

    if (!$marketWait -and $Saved.rank -ge $regions[1200].requiredRanks -and ($needsShells -or $needsObsidian)) {
        if ($needsShells -and !$marketBusy -and
            (!$needsObsidian -or ($desiredVials -gt 0 -and !$exchangeBudget) -or ($completed+$recoveredMining)%3 -eq 0)) {
            $revenue = Get-RevenuePlan $Saved 1200 1200 $needsObsidian '1200m Magma Abyss for original shells and obsidian'
            $revenue.finance = $finance
            return $revenue
        }
        if ($needsObsidian) {
            return @{kind='Resource';key='resource-obsidian-1200';depth=1200;currency='obsidian';sector='West';
                purpose='1200m Magma Abyss for remaining obsidian ranks';finance=$finance;
                deferShopPayout=$canDeferGoldenBacklog -or $marketBusy -or $pendingShells -gt 0}
        }
    }

    foreach ($currency in 'crystals','mushrooms','scrap') {
        if ($needed[$currency] -le 0) { continue }
        $depth = switch ($currency) { 'crystals' {500}; 'mushrooms' {900}; 'scrap' {300} }
        if ($Saved.rank -lt $regions[$depth].requiredRanks) { continue }
        $key = "resource-$currency-$depth"
        $nextCost = $Audit.missingNodes.Keys | Where-Object {
            Test-MaxRankPrerequisites $maxRankProof.nodes[$_] $Saved.ranks
        } | ForEach-Object { $Audit.missingNodes[$_].prices[0] } | Where-Object {
            $_.currency -eq $currency -and $_.price -gt $Saved.wallet[$currency]
        } | Sort-Object { $_.price } | Select-Object -First 1
        $shortfall = if ($nextCost) { $nextCost.price-$Saved.wallet[$currency] } else { $needed[$currency] }
        $observedYield = [decimal]$script:materialRoundYield[$key]
        $rounds = if ($observedYield -gt 0) { [int][Math]::Min($MiningRounds,[Math]::Ceiling($shortfall/$observedYield)) } else { 1 }
        return @{ kind='Resource'; key=$key;depth=$depth;currency=$currency;sector='West';materialException=$true;
            rounds=$rounds;shortfallToNextRank=$shortfall;verifiedPriorRoundYield=$observedYield;
            deferShopPayout=$marketBusy -or $pendingShells -gt 0;
            purpose="Targeted $depth m expedition for the next original $currency rank" }
    }
    if ($marketWait) { return $marketWait }
    if ($marketBusy -or $script:unconfirmedShopCredit) {
        return @{kind='WaitMarket';key='market-native-processing';purpose='Observe original station production while no other action can advance'}
    }
    if ($Saved.rank -lt $regions[1200].requiredRanks) {
        return @{kind='Blocked';reason='No further affordable original ranks were found and 1200m has not unlocked.'}
    }
    return @{kind='Blocked';reason='No eligible original purchase or verified material route advances the remaining ranks.'}
}

function Wait-ProgressionMarket($Initial) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = $Initial.nativeSave
    do {
        if (Test-ProgressionStopped) { throw [OperationCanceledException]::new('Shelldiver session stop requested.') }
        $sample = Get-IslandStatus
        $current = $sample.nativeSave
        if ($sample.frame -gt $Initial.frame -and $current.sha256 -ne $last.sha256 -and
            ($current.shellCoins -gt $last.shellCoins -or $current.storeShellCoins -gt $last.storeShellCoins -or
                $current.transmutatorInputJellyfish -ne $last.transmutatorInputJellyfish -or
                $current.transmutatorOutputJellyfish -ne $last.transmutatorOutputJellyfish -or
                $current.storeQueuedJellyfish -ne $last.storeQueuedJellyfish -or
                $current.submarineJellyfish -ne $last.submarineJellyfish -or
                $current.playerJellyfish -ne $last.playerJellyfish)) {
            return @{pid=$gamePid;phase='processing';beforeHash=$last.sha256;afterHash=$current.sha256;frame=$sample.frame}
        }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt 8)
    return @{pid=$gamePid;phase='unchanged';beforeHash=$last.sha256}
}

function Confirm-MaxRankComplete($Saved) {
    if ($Saved.rank -ne 800) { throw 'The original save does not contain exactly 800 ranks.' }
    for ($attempt=0; $attempt -lt 3; ++$attempt) {
        $live = Read-MaxRankCatalog -Live
        $mismatches = @($live.nodes.Keys | Where-Object {
            $live.nodes[$_].nativeRank -ne $live.nodes[$_].maxRank -or $live.nodes[$_].nativeRank -ne [int]$Saved.ranks[$_]
        })
        if ($live.reportedRank -eq 800 -and !$mismatches.Count) {
            return @{ pid=$gamePid; nativeRanks=800; savedRanks=800; verifiedNodes=241; prestige=$live.prestige }
        }
        Start-Sleep -Milliseconds 160
    }
    throw 'The resident game and original save did not agree on all 241 maxed skill nodes.'
}

function Wait-ProgressionIsland([string]$After) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $readyFrame = $null
    do {
        try {
            $state = Get-IslandStatus
            if ($null -eq $state.frame) { throw 'No native frame is available to verify the island recovery.' }
            if ($null -eq $readyFrame) { $readyFrame = [long]$state.frame }
            if ($state.frame -ge $readyFrame + 30) { return $state }
        } catch {
            if ($_.Exception.Message -ne 'Progression requires the resident Shelldiver game on its settled island.') { throw }
            $readyFrame = $null
        }
        Start-Sleep -Milliseconds 50
    } while ($deadline.Elapsed.TotalSeconds -lt 7)
    throw "The native island did not settle after $After."
}

function Get-UpgradeRankEvidence($Before, $After, $Purchases) {
    $targets = @{}
    foreach ($purchase in $Purchases) { $targets[$purchase.id] = [int]$purchase.rank }
    $gains = [ordered]@{}
    foreach ($id in @($Before.ranks.Keys) + @($After.ranks.Keys) | Sort-Object -Unique) {
        $initial = [int]$Before.ranks[$id]
        $actual = [int]$After.ranks[$id]
        if ($actual -eq $initial) { continue }
        if ($actual -lt $initial -or !$targets.ContainsKey($id) -or $actual -gt $targets[$id]) {
            throw "Native save recorded an unplanned rank change for $id ($initial to $actual)."
        }
        $gains[$id] = @{ before=$initial; after=$actual; planned=$targets[$id] }
    }
    $reachedAll = @($targets.Keys | Where-Object { [int]$After.ranks[$_] -ne $targets[$_] }).Count -eq 0
    return @{ gains=$gains; reachedAll=$reachedAll }
}

function Test-FreshProgressionFrame($State, [long]$AfterFrame) {
    if (!$State.writtenUtc -or $null -eq $State.frame -or $State.frame -le $AfterFrame) { return $false }
    $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]$State.writtenUtc
    return $age.TotalSeconds -ge -1 -and $age.TotalSeconds -le 4
}

function Get-OwnedFailedDive($Initial, [DateTime]$ActionStarted, [string]$Failure) {
    $live = Get-IslandStatus -Preview
    $actor = $live.session
    if ($live.pid -ne $gamePid -or $live.room -ne $regions[1200].room -or
        !(Test-FreshProgressionFrame $live $Initial.frame) -or
        $live.activeInputFrames -ne 0 -or $live.virtualPointerActive -or
        ($live.inputError -and $live.inputError -ne 'Could not publish the game mailbox response.') -or
        $actor.phase -ne 'ended' -or $actor.action -ne 'Run' -or $actor.hostPid -ne $PID -or
        $actor.gamePid -ne $gamePid -or $actor.startedTicks -lt $ActionStarted.Ticks -or $actor.message -ne $Failure -or
        !$live.nativeSave.sha256) {
        throw $Failure
    }
    return $live
}

function Recover-ProgressionHarvest($Initial, [DateTime]$ActionStarted, [string]$Failure, $NativeReceipt) {
    $nativeMailbox = Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'
    $nativeSave = Join-Path $env:APPDATA 'Shelldiver/save/Game.json'
    if ([IO.Path]::GetFullPath($Mailbox) -ne [IO.Path]::GetFullPath($nativeMailbox) -or
        [IO.Path]::GetFullPath($SavePath) -ne [IO.Path]::GetFullPath($nativeSave) -or
        !(Test-Path -LiteralPath $resumeHarvest -PathType Leaf)) { throw $Failure }

    $live = Get-OwnedFailedDive $Initial $ActionStarted $Failure
    Assert-SessionMailboxIdle

    $recovery = [ordered]@{phase='resuming'; pid=$gamePid; sourceFrame=$live.frame; originalFailure=$Failure;
        originalReceipt=$NativeReceipt; nativeBalanceVerified=$false; landed=$null; transfer=$null;
        payout=$null; deposited=0; withdrawn=0; catch=0; error=$null}
    $receipt.harvestRecoveries.Add($recovery)
    Write-ProgressionState $receipt
    try {
        $landed = & $resumeHarvest -ExpectedPid $gamePid
        $recovery.landed = $landed
        $island = Wait-ProgressionIsland 'the resumed expedition'
        if ($landed.pid -ne $gamePid -or $landed.room -ne 'rm_main_island' -or $island.frame -le $live.frame -or
            !$landed.nativeSaveAfter.sha256 -or !$island.nativeSave.sha256 -or
            $null -eq $landed.nativeSaveAfter.playerJellyfish -or $null -eq $Initial.nativeSave.playerJellyfish -or
            $landed.nativeSaveAfter.playerJellyfish -ne $island.nativeSave.playerJellyfish -or
            $landed.nativeSaveAfter.submarineJellyfish -ne $island.nativeSave.submarineJellyfish -or
            $landed.nativeSaveAfter.playerJellyfish -lt $Initial.nativeSave.playerJellyfish) {
            throw 'The resumed expedition did not verify the native island save and retained catch.'
        }
        $recovery.catch = [long]$island.nativeSave.playerJellyfish - [long]$Initial.nativeSave.playerJellyfish
        if (Test-ProgressionStopped) { throw 'Shelldiver session stop requested.' }
        if ($island.nativeSave.playerJellyfish -gt 0) {
            $recovery.phase = 'converting'
            Write-ProgressionState $receipt
            $station = & $transmutator -Action Status -ControllerRoot $ControllerRoot @common
            if (!$station.unlocked -or !$station.automaticOutput -or $station.unsupportedSkills.Count -or
                $station.outputType -notin 1,2 -or $null -eq $station.inventories.player) {
                throw 'The rescued catch needs the native automatic-output transmutator before settlement.'
            }
            $eligible = @($station.inventories.player.Keys | Where-Object { [int](($_ -split ',')[1]) -lt $station.outputType })
            if ($eligible.Count) {
                $trade = & $transmutator -Action TransferAll -ControllerRoot $ControllerRoot -TimeoutSeconds 240 @common
                $recovery.transfer = $trade
                if ($trade.pid -ne $gamePid -or $trade.phase -ne 'transferred' -or !$trade.automaticOutput -or
                    $trade.outputType -ne $station.outputType -or $trade.deposited -le 0 -or
                    $null -eq $trade.after.player -or
                    @($trade.after.player.Keys | Where-Object { [int](($_ -split ',')[1]) -lt $station.outputType }).Count) {
                    throw 'The original transmutator did not verify the complete typed rescue transfer.'
                }
                $recovery.deposited = $trade.deposited
            }
        }
        $island = if ($recovery.transfer) { Wait-ProgressionIsland 'the rescue transfer' } else { Get-IslandStatus }
        if (Test-ProgressionStopped) { throw 'Shelldiver session stop requested.' }
        if ($island.nativeSave.playerJellyfish -gt 0 -or $island.nativeSave.submarineJellyfish -gt 0 -or
            $island.nativeSave.storeQueuedJellyfish -gt 0 -or $island.nativeSave.storeShellCoins -gt 0) {
            $recovery.phase = 'settling'
            Write-ProgressionState $receipt
            $payout = & $session -Action Settle -TimeoutSeconds 180 @common
            $recovery.payout = $payout
            $island = Wait-ProgressionIsland 'the rescued catch settlement'
            if ($payout.pid -ne $gamePid -or $payout.room -ne 'rm_main_island' -or
                !$payout.nativeSaveBefore.sha256 -or !$payout.nativeSaveAfter.sha256 -or !$island.nativeSave.sha256 -or
                $null -eq $payout.nativeSaveBefore.shellCoins -or $null -eq $payout.nativeSaveBefore.storeShellCoins -or
                $null -eq $payout.nativeSaveAfter.shellCoins -or
                $payout.nativeSaveAfter.shellCoins -lt ($payout.nativeSaveBefore.shellCoins + $payout.nativeSaveBefore.storeShellCoins) -or
                $payout.nativeSaveAfter.playerJellyfish -ne 0 -or $payout.nativeSaveAfter.submarineJellyfish -ne 0) {
                throw 'The rescued expedition did not verify the native shop settlement.'
            }
        }
        $recovery.nativeBalanceVerified = $true
        $recovery.phase = 'recovered'
        return $recovery
    } catch {
        $recovery.phase = if (Test-ProgressionStopped) { 'stopped' } else { 'blocked' }
        $recovery.error = $_.Exception.Message
        throw
    }
}

function Read-ProgressionMiningSnapshot([long]$AfterFrame) {
    $sample = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds 3
    if ($sample.pid -ne $gamePid -or $sample.room -ne $regions[1200].room -or
        !(Test-FreshProgressionFrame $sample $AfterFrame) -or !$sample.inputReady -or
        ($sample.inputError -and $sample.inputError -ne 'Could not publish the game mailbox response.') -or
        $sample.activeInputFrames -ne 0 -or $sample.guiPointer.active -or !$sample.guiPointer.buttonHooks -or
        $sample.flags.pause -or $sample.flags.transitioning -or $sample.flags.in_cutscene -or
        $sample.flags.player_inventory_open -or $sample.scene.player.oxygen -le 0) {
        throw 'A fresh live Magma Abyss dive or stock result could not be verified for mining recovery.'
    }
    return $sample
}

function Recover-ProgressionMining($Initial, [DateTime]$ActionStarted, [string]$Failure, $NativeReceipt, $Plan) {
    $sessionLock = Join-Path $Mailbox 'session.lock'
    try {
        $returnLease = [IO.File]::Open($sessionLock, 'OpenOrCreate', 'Write', 'None')
    } catch [IO.IOException] {
        throw 'A live Shelldiver session is already using this mailbox.'
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $recovery = $null
    try {
        try {
            $live = Get-OwnedFailedDive $Initial $ActionStarted $Failure
            $source = Read-ProgressionMiningSnapshot ($live.frame - 1)
            $player = $source.scene.player
            $hatch = $source.scene.submarineLeave
            if ($player.can_use_tool -ne 1 -or !$hatch.can_be_used -or $hatch.range -lt 40 -or
                $null -eq $player.x -or $null -eq $player.y -or $null -eq $hatch.x -or $null -eq $hatch.y -or
                $null -eq $player.frame -or $player.frame -gt $source.frame -or $source.frame - $player.frame -gt 45 -or
                $null -eq $hatch.frame -or $hatch.frame -gt $source.frame -or $source.frame - $hatch.frame -gt 45 -or
                $live.nativeSave.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $null -eq $live.nativeSave.wallet.obsidian) {
                throw 'The original diver, hatch, and mining save are not ready for recovery.'
            }
            if (Test-ProgressionStopped) { throw 'Shelldiver session stop requested.' }
            $dx = [double]$player.x - [double]$hatch.x
            $dy = [double]$player.y - [double]$hatch.y
            $distance = [Math]::Sqrt($dx*$dx + $dy*$dy)
            # The stock Return wrapper already docks directly within this live range margin.
            $recovery = [ordered]@{
                phase='returning'; stage='mining'; batchCompleted=$false; pid=$gamePid; depth=1200
                plannedRounds=if ($Plan.kind -eq 'Conversion') { $Plan.miningRounds } else { $MiningRounds }
                sourceFrame=$source.frame; oxygen=$player.oxygen; distanceToHatchAnchor=$distance; nativeHatchRange=$hatch.range
                directDockEligible=$distance -le $hatch.range-24
                originalFailure=$Failure; originalReceipt=$NativeReceipt; before=$live.nativeSave
                returned=$null; checkpoint=$null; landed=$null; savedObsidianGain=$null; nativeBalanceVerified=$false
                deposited=$NativeReceipt.deposited; withdrawn=$NativeReceipt.withdrawn
                elapsedMs=$null; error=$null
            }
            $receipt.miningRecoveries.Add($recovery)
            Write-ProgressionState $receipt

            $priorStopPath = $env:SHELLDIVER_SESSION_STOP_PATH
            $priorStartedTicks = $env:SHELLDIVER_SESSION_STARTED_TICKS
            try {
                $env:SHELLDIVER_SESSION_STOP_PATH = $stopPath
                $env:SHELLDIVER_SESSION_STARTED_TICKS = [string]$started.Ticks
                $arguments = @{
                    Action='Return'; Kind='Resource'; HoldResult=$true; RequireLiveDiver=$true; RecoverMagma=$true
                    MagmaMineSector=if ($Plan.sector) { $Plan.sector } else { 'West' }
                    MagmaShockResistance=[bool]$live.nativeSave.magmaShockResistance
                    MagmaShockFrequency=[bool]$live.nativeSave.magmaShockFrequency
                    MagmaShockResistanceII=[bool]$live.nativeSave.magmaShockResistanceII
                    UseSubmarineBubble=[bool]$live.nativeSave.submarineBubbleOwned
                    UseSubmarineAmmoBubble=[bool]$live.nativeSave.submarineAmmoBubbleOwned
                    BeforeDiveSaveHash=$live.nativeSave.sha256; TimeoutSeconds=24
                }
                $returned = & $dive @arguments @common
                $recovery.returned = $returned
            } finally {
                $env:SHELLDIVER_SESSION_STOP_PATH = $priorStopPath
                $env:SHELLDIVER_SESSION_STARTED_TICKS = $priorStartedTicks
            }
        } finally {
            $returnLease.Dispose()
        }

        if (Test-ProgressionStopped) { throw 'Shelldiver session stop requested.' }
        if ($returned.pid -ne $gamePid -or $returned.room -ne $regions[1200].room -or
            $returned.frame -le $source.frame -or $returned.scene.player.can_use_tool -ne 0) {
            throw 'The original mining return did not produce its held expedition result.'
        }
        $result = Read-ProgressionMiningSnapshot ($returned.frame - 1)
        $resultSave = Get-OwnedFailedDive $Initial $ActionStarted $Failure
        $checkpoint = Get-Content -LiteralPath (Join-Path $Mailbox 'dive-return.json') -Raw | ConvertFrom-Json
        if ($result.scene.player.can_use_tool -ne 0 -or $checkpoint.pid -ne $gamePid -or
            $checkpoint.stateFrame -lt $source.frame -or $checkpoint.stateFrame -gt $result.frame -or
            $checkpoint.beforeHash -ne $live.nativeSave.sha256 -or !$checkpoint.expectedHash -or
            $checkpoint.expectedHash -eq $checkpoint.beforeHash -or $checkpoint.expectedHash -ne $resultSave.nativeSave.sha256 -or
            $resultSave.frame -lt $result.frame -or
            $null -eq $resultSave.nativeSave.wallet.obsidian -or $resultSave.nativeSave.wallet.obsidian -lt $live.nativeSave.wallet.obsidian) {
            throw 'The same-process stock mining result and its new original save were not verified.'
        }
        Assert-SessionMailboxIdle
        if (Test-ProgressionStopped) { throw 'Shelldiver session stop requested.' }
        $recovery.checkpoint = $checkpoint
        $recovery.phase = 'finishing-result'
        Write-ProgressionState $receipt
        $landed = & $session -Action FinishResult -Depth 1200 -ResultVerified -TimeoutSeconds 45 @common
        $recovery.landed = $landed
        $island = Wait-ProgressionIsland 'the recovered mining return'
        if ($landed.pid -ne $gamePid -or $landed.room -ne 'rm_main_island' -or $island.frame -le $result.frame -or
            $landed.nativeSaveBefore.sha256 -ne $checkpoint.expectedHash -or !$landed.nativeSaveAfter.sha256 -or
            !$island.nativeSave.sha256 -or $null -eq $landed.nativeSaveAfter.wallet.obsidian -or
            $landed.nativeSaveAfter.wallet.obsidian -ne $resultSave.nativeSave.wallet.obsidian -or
            $island.nativeSave.wallet.obsidian -ne $landed.nativeSaveAfter.wallet.obsidian) {
            throw 'The recovered mining haul could not be verified in the settled original island save.'
        }
        $recovery.savedObsidianGain = $island.nativeSave.wallet.obsidian - $live.nativeSave.wallet.obsidian
        $recovery.nativeBalanceVerified = $true
        $recovery.phase = 'recovered-return'
        return $recovery
    } catch {
        if ($recovery) {
            $recovery.phase = if (Test-ProgressionStopped) { 'stopped' } else { 'blocked' }
            $recovery.error = $_.Exception.Message
        }
        throw
    } finally {
        if ($recovery) { $recovery.elapsedMs = $watch.ElapsedMilliseconds }
    }
}

function Test-ProgressionStopped {
    if (![IO.File]::Exists($stopPath)) { return $false }
    try {
        $signal = Get-Content -Raw -LiteralPath $stopPath | ConvertFrom-Json
        return [long]$signal.requestedTicks -ge $started.Ticks
    } catch [IO.IOException] {
        return $false
    }
}

function Write-ProgressionState($Value) {
    $temporary = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 12))
        [IO.File]::Move($temporary,$statePath,$true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

$state = Get-IslandStatus -Preview:($Action -eq 'Plan')
$gamePid = $state.pid
$saved = Read-ProgressionSave
if ($Action -eq 'Plan') {
    $plan = [ordered]@{profile=$Profile;pid=$gamePid;room=$state.room;rank=$saved.rank;wallet=$saved.wallet}
    if ($Profile -eq 'MaxRanks') {
        $maxRankProof = Read-MaxRankCatalog
        $plan.audit = Get-MaxRankAudit $saved $maxRankProof
        $plan.next = Get-MaxRankPlan $saved $state $plan.audit
    } else {
        $plan.next = Get-ProgressionPlan $saved $state
    }
    return $plan
}
$lease = [IO.File]::Open((Join-Path $Mailbox 'progression.lock'),'OpenOrCreate','Write','None')
$receipt = [ordered]@{ phase='running'; profile=$Profile; pid=$gamePid; startedUtc=$started.ToString('o'); completed=0; rank=$saved.rank;
    wallet=$saved.wallet; next=$null; last=$null; audit=$null; acceptance=$null; upgradeRecoveries=[Collections.Generic.List[object]]::new();
    harvestRecoveries=[Collections.Generic.List[object]]::new(); miningRecoveries=[Collections.Generic.List[object]]::new();
    recoveredMining=0; error=$null }
try {
    if ($Profile -eq 'MaxRanks') { $maxRankProof = Read-MaxRankCatalog -Live }
    while (!$MaxActions -or $completed + $recoveredMining -lt $MaxActions) {
        if (Test-ProgressionStopped) { $receipt.phase='stopped'; break }
        $state = Get-IslandStatus
        $saved = Read-ProgressionSave
        if ($Profile -eq 'MaxRanks') {
            $receipt.audit = Get-MaxRankAudit $saved $maxRankProof
            $plan = Get-MaxRankPlan $saved $state $receipt.audit
        } else {
            $plan = Get-ProgressionPlan $saved $state
        }
        $receipt.next = $plan
        if ($plan.kind -eq 'Complete') {
            if ($Profile -eq 'MaxRanks') { $receipt.acceptance = Confirm-MaxRankComplete $saved }
            $receipt.phase='complete'
            break
        }
        if ($plan.kind -eq 'Blocked') { throw $plan.reason }
        if ($failures[$plan.key] -ge 4) { throw "Four settled actions made no progress for $($plan.key)." }
        Write-ProgressionState $receipt

        $upgradeError = $null
        $fishingError = $null
        $miningError = $null
        $actionStarted = [DateTime]::UtcNow
        $plasmaPulse = Get-ProgressionPlasmaPulse $plan $state
        $result = switch ($plan.kind) {
            'End' { & $ending -TimeoutSeconds 120 @common }
            'Settle' { & $session -Action Settle -DeferShopPayout:([bool]$plan.deferShopPayout) -TimeoutSeconds 180 @common }
            'CollectShopCredit' { & $session -Action CollectShopCredit -TimeoutSeconds 25 @common }
            'QueueGoldTail' { Invoke-ProgressionGoldTailSale }
            'WaitMarket' { Wait-ProgressionMarket $state }
            'Unlock' { & $campaign -Rounds 0 -Cycles 2 -UseStockCatalog -StopAtRank $plan.rank -TimeoutSeconds 240 @common }
            'Upgrade' {
                try {
                    & $upgrade -Skill @($plan.purchases | ForEach-Object id) -KeepCameraPosition -TimeoutSeconds ([Math]::Min(90, 60+2*$plan.purchases.Count)) @common
                } catch {
                    $message = $_.Exception.Message
                    if ($message -notlike 'Unexpected native skill changes while trying to buy *' -and
                        $message -notin 'The native purchase was accepted and is awaiting its save.',
                            'The resident skill panel is no longer available.') { throw }
                    $upgradeError = $message
                }
            }
            'Alchemy' { & $alchemy -Vials $plan.count @common }
            'ConvertCatch' {
                $transfer = if ($plan.transferAction) { $plan.transferAction } else { 'TransferAll' }
                $budget = if ($transfer -eq 'TransferAll') { 240 } else { 25 }
                $transferArguments = @{Action=$transfer;TimeoutSeconds=$budget;ControllerRoot=$ControllerRoot}
                if ($transfer -eq 'Transfer') { $transferArguments.Frames = 120 }
                & $transmutator @transferArguments @common
            }
            'CatchForGold' {
                try {
                    Finish-ProgressionGoldenCatch $plan.depth
                } catch {
                    if ($plan.depth -ne 1200 -or $_.Exception.GetBaseException() -is [OperationCanceledException]) { throw }
                    $fishingError = $_.Exception.Message
                }
            }
            'Fish' {
                try {
                    & $session -Action Run -Depth $plan.depth -Kind Jellyfish -Rounds 1 -FillBackpack -BatchSettlement @common
                } catch {
                    if ($plan.depth -ne 1200 -or $_.Exception.GetBaseException() -is [OperationCanceledException]) { throw }
                    $fishingError = $_.Exception.Message
                }
            }
            'Conversion' { & $conversion -FishingDepth $plan.fishingDepth -MiningDepth $plan.depth -FishingRounds 1 -MiningRounds $plan.miningRounds -MiningEmptyLimit 2 -MiningHarvestSeconds $MiningHarvestSeconds -PlasmaHoldFrames $plasmaPulse -TimeoutSeconds 540 -ControllerRoot $ControllerRoot @common }
            'Resource' {
                try {
                    if ($plan.materialException -and $state.nativeSave.storageAutoOutput) {
                        Invoke-ProgressionMaterialTrips $plan $state $plasmaPulse
                        break
                    }
                    $roundsToRun = if ($plan.rounds) { $plan.rounds } else { $MiningRounds }
                    & $session -Action Run -Depth $plan.depth -Kind Resource -Rounds $roundsToRun -BatchSettlement -ReturnBetweenRounds -DeferShopPayout:([bool]$plan.deferShopPayout) -StopAfterEmptyResourceRounds 2 -MagmaMineSector $plan.sector -HarvestSeconds $MiningHarvestSeconds -PlasmaHoldFrames $plasmaPulse -TimeoutSeconds 510 @common
                } catch {
                    if ($plan.depth -ne 1200 -or $_.Exception.GetBaseException() -is [OperationCanceledException]) { throw }
                    $miningError = $_.Exception.Message
                }
            }
            default { throw "Unsupported progression action $($plan.kind)." }
        }

        if ($plan.kind -eq 'Conversion' -and $plan.fishingDepth -eq 1200 -and
            $result.phase -eq 'blocked' -and $result.stage -eq 'fishing' -and $result.pid -eq $gamePid) {
            $fishingError = $result.error
        }
        if ($plan.kind -eq 'Conversion' -and $plan.depth -eq 1200 -and
            $result.phase -eq 'blocked' -and $result.stage -eq 'mining' -and $result.pid -eq $gamePid) {
            $miningError = $result.error
        }
        if ($miningError) {
            if (Test-ProgressionStopped) { $receipt.phase = 'stopped'; break }
            $result = Recover-ProgressionMining $state $actionStarted $miningError $result $plan
        }
        if ($fishingError) {
            if (Test-ProgressionStopped) { $receipt.phase = 'stopped'; break }
            $result = Recover-ProgressionHarvest $state $actionStarted $fishingError $result
        }
        $succeeded = if ($upgradeError) { Wait-ProgressionIsland 'the upgrade report' } else { Get-IslandStatus }
        $after = Read-ProgressionSave
        if ($result.pid -and $result.pid -ne $gamePid) { throw 'The native action returned a different Shelldiver PID.' }
        if (Test-ProgressionStopped) { $receipt.phase='stopped'; break }
        if ($result.phase -eq 'blocked' -or $result.phase -eq 'failed') {
            throw "Native $($plan.kind) stopped at $($result.stage): $($result.error)"
        }
        if ($plan.kind -eq 'CollectShopCredit') {
            $collection = $result.shopCollection
            if ($result.pid -ne $gamePid -or $collection.phase -notin 'paid','no-earnings','waiting-native-save') {
                throw 'The native partial shop collection did not report a recognized result.'
            }
            if ($collection.phase -eq 'paid') {
                if (!$result.nativeSaveBefore.sha256 -or !$result.nativeSaveAfter.sha256 -or $collection.paidShells -le 0 -or
                    $after.wallet.shells-$saved.wallet.shells -lt $collection.paidShells) {
                    throw 'The original save did not verify the partial shop payment.'
                }
                $script:unconfirmedShopCredit = $null
            } elseif ($collection.phase -eq 'waiting-native-save') {
                $script:unconfirmedShopCredit = @{beforeShells=$saved.wallet.shells}
            }
        }
        if ($plan.kind -eq 'ConvertCatch' -and ($result.phase -ne 'transferred' -or $result.pid -ne $gamePid -or
            $result.outputType -ne 2 -or !$result.automaticOutput -or $result.deposited -lt 0 -or $null -eq $result.deposited -or
            (!$result.deposited -and ($plan.transferAction -ne 'TransferReady' -or $result.stopReason -notin 'input-full','backpack-cleared')) -or
            $state.nativeSave.playerTransmutable-$succeeded.nativeSave.playerTransmutable -ne $result.deposited)) {
            throw 'The saved eligible backpack reduction did not verify the native Golden transfer.'
        }
        if ($plan.kind -in 'Fish','Resource','CatchForGold' -and !$result.nativeBalanceVerified) {
            throw 'The native expedition did not confirm original save settlement.'
        }
        if ($plan.materialException) {
            $verifiedYield = @($result.rounds | Where-Object {
                $_.depth -eq $plan.depth -and $_.nativeBalanceVerified -eq $true -and
                    $_.nativeOxygenLoss -eq $false -and $_.nativeWalletDelta[$plan.currency] -gt 0
            } | ForEach-Object { [decimal]$_.nativeWalletDelta[$plan.currency] })
            if ($verifiedYield.Count) {
                $script:materialRoundYield[$plan.key] = ($verifiedYield | Measure-Object -Minimum).Minimum
            }
        }
        if ($plan.kind -eq 'Upgrade') {
            $ranks = Get-UpgradeRankEvidence $saved $after $plan.purchases
            if (!$ranks.gains.Count) {
                if ($upgradeError) { throw $upgradeError }
                throw 'Native save did not confirm any planned skill purchase.'
            }
            if ($Profile -eq 'MaxRanks') {
                $lastSavedPurchase = $plan.purchases | Where-Object {
                    $ranks.gains[$_.id] -and $_.rank -le $ranks.gains[$_.id].after
                } | Select-Object -Last 1
                if ($lastSavedPurchase) { $script:maxRankLastNode = $maxRankProof.nodes[$lastSavedPurchase.id] }
            }
            if ($upgradeError -or !$ranks.reachedAll) {
                $receipt.upgradeRecoveries.Add(@{
                    action=$completed+1; frame=$succeeded.frame; gains=$ranks.gains; reachedAll=$ranks.reachedAll
                    reportedError=$upgradeError; walletBefore=$saved.wallet; walletAfter=$after.wallet; native=$result
                })
            }
        }
        if ($plan.kind -eq 'End' -and (!$after.finished -or $after.ranks.o_skill_hammock -lt 1)) { throw 'Native save did not verify the hammock ending.' }
        $progress = switch ($plan.kind) {
            'Fish' { $after.wallet.shells -gt $saved.wallet.shells -or $succeeded.nativeSave.storeShellCoins -gt 0 -or $result.deposited -gt 0 }
            'ConvertCatch' { $result.deposited -gt 0 }
            'CollectShopCredit' { $result.shopCollection.phase -eq 'paid' -and $after.wallet.shells -gt $saved.wallet.shells }
            'QueueGoldTail' { $result.phase -eq 'queued' -and $result.queuedFromBackpack -gt 0 }
            'WaitMarket' { $result.phase -eq 'processing' }
            'CatchForGold' { $succeeded.nativeSave.playerJellyfish -gt $state.nativeSave.playerJellyfish -or
                $succeeded.nativeSave.submarineJellyfish -gt $state.nativeSave.submarineJellyfish -or
                $result.automaticCatchRouting.creditedShells -gt 0 -or $result.deposited -gt 0 -or
                $succeeded.nativeSave.transmutatorInputJellyfish -gt $state.nativeSave.transmutatorInputJellyfish -or
                $succeeded.nativeSave.transmutatorOutputJellyfish -gt $state.nativeSave.transmutatorOutputJellyfish }
            'Resource' { $after.wallet[$plan.currency] -gt $saved.wallet[$plan.currency] }
            'Conversion' { $after.wallet.obsidian -gt $saved.wallet.obsidian -or $after.wallet.shells -gt $saved.wallet.shells -or
                $result.deposited -gt 0 -or $result.withdrawn -gt 0 -or $result.fishingCatch -gt 0 -or
                $succeeded.nativeSave.storeShellCoins -gt 0 }
            'Alchemy' { $after.wallet.lifeVials -gt $saved.wallet.lifeVials }
            'Settle' { $after.wallet.shells -gt $saved.wallet.shells -or
                ($succeeded.nativeSave.playerJellyfish -eq 0 -and $succeeded.nativeSave.submarineJellyfish -eq 0 -and
                 $succeeded.nativeSave.storeQueuedJellyfish -eq 0 -and $succeeded.nativeSave.storeShellCoins -eq 0) }
            default { $after.rank -gt $saved.rank -or $after.finished }
        }
        if ($progress) { $failures[$plan.key] = 0 } else { $failures[$plan.key] = [int]$failures[$plan.key] + 1 }
        $receipt.last = @{ kind=$plan.kind; depth=$plan.depth; progressed=[bool]$progress; timeUtc=[DateTime]::UtcNow.ToString('o');
            walletBefore=$saved.wallet; walletAfter=$after.wallet; departure=$plan.departure; native=$result }
        $receipt.rank = $after.rank
        $receipt.wallet = $after.wallet
        if ($miningError) { $receipt.recoveredMining = ++$recoveredMining }
        else { $receipt.completed = ++$completed }
        if ($Profile -eq 'MaxRanks') {
            $delta = [ordered]@{}
            foreach ($currency in $walletFields.Keys) {
                $delta[$currency] = [decimal]$after.wallet[$currency] - [decimal]$saved.wallet[$currency]
            }
            $rounds = @($result.rounds) + @($result.mining.rounds)
            $verifiedRounds = @($rounds | Where-Object { $null -ne $_.nativeOxygenLoss })
            $losses = if ($verifiedRounds.Count) { @($verifiedRounds | Where-Object nativeOxygenLoss).Count }
            $record = [ordered]@{
                atUtc=$receipt.last.timeUtc; pid=$gamePid; kind=$plan.kind; depth=$plan.depth
                rankBefore=$saved.rank; rankAfter=$after.rank; walletDelta=$delta
                elapsedMs=[long]([DateTime]::UtcNow-$actionStarted).TotalMilliseconds
                verifiedDiveRounds=$verifiedRounds.Count; nativeOxygenLosses=$losses
                backpackDeparture=if ($result.departure) { $result.departure } else { $plan.departure }
            }
            try {
                $record | ConvertTo-Json -Compress -Depth 4 | Add-Content -LiteralPath (Join-Path (Split-Path -Parent $Mailbox) 'maxrank-actions.jsonl') -ErrorAction Stop
            } catch [IO.IOException] {
                Write-Warning "Could not append the verified action to the wall-clock log. $($_.Exception.Message)"
            }
            $receipt.audit = Get-MaxRankAudit $after $maxRankProof
            if (!$receipt.audit.missingRanks) {
                $receipt.acceptance = Confirm-MaxRankComplete $after
                $receipt.next = @{kind='Complete';target=800}
                $receipt.phase='complete'
                break
            }
        } elseif ($after.finished -and $after.ranks.o_skill_hammock -ge 1) { $receipt.phase='complete'; break }
        Write-ProgressionState $receipt
    }
    if ($receipt.phase -eq 'running') { $receipt.phase='paused-at-action-limit' }
} catch {
    $receipt.phase = if (Test-ProgressionStopped) { 'stopped' } else { 'blocked' }
    if ($receipt.phase -eq 'blocked') { $receipt.error = $_.Exception.Message }
} finally {
    $receipt.finishedUtc = [DateTime]::UtcNow.ToString('o')
    try { Write-ProgressionState $receipt } finally { $lease.Dispose() }
}
$receipt
