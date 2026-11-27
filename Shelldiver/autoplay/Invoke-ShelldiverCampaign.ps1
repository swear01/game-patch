#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1, 6)] [int]$Cycles = 2,
    [ValidateRange(0, 12)] [int]$Rounds = 3,
    [ValidateRange(0, 800)] [int]$StopAtRank,
    [ValidateRange(0, 100)] [int]$ExchangeVials,
    [ValidateSet(100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200)] [int]$Depth = 100,
    [ValidateSet('Alternate', 'Resource', 'Jellyfish', 'Mixed')] [string]$Kind = 'Alternate',
    [ValidateSet(0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200)]
    [int]$FollowUpResourceDepth,
    [ValidateRange(100, 200)] [int]$PlasmaHoldFrames = 200,
    [switch]$UseStockCatalog,
    [ValidateRange(1, 35)] [int]$HarvestSeconds = 6,
    [ValidateRange(35, 95)] [int]$ReturnOxygen = 65,
    [ValidateRange(30, 900)] [int]$TimeoutSeconds = 240,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json')
)

$ErrorActionPreference = 'Stop'
if ($Kind -eq 'Mixed' -and $Depth -notin 700, 800, 900) { throw 'Mixed harvesting is supported at 700, 800 and 900 meters.' }
if ($FollowUpResourceDepth -and ($Kind -ne 'Jellyfish' -or $Rounds -eq 0)) {
    throw 'Deferred shop payout requires a Jellyfish batch with at least one expedition per depth.'
}
$walletFields = @{
    shells='shell_coins'; scrap='scrap_coins'; crystals='crystal_coins'
    mushrooms='mushroom_coins'; obsidian='obsidian_coins'; lifeVials='flask_coins'
}
$session = Join-Path $PSScriptRoot 'Invoke-ShelldiverSession.ps1'
$upgrade = Join-Path $PSScriptRoot 'Invoke-ShelldiverUpgrade.ps1'
$alchemy = Join-Path $PSScriptRoot 'Invoke-ShelldiverAlchemy.ps1'
$pendingExchanges = $ExchangeVials
$Mailbox = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Mailbox)
$stopPath = Join-Path $Mailbox 'session.stop.json'
$startedUtc = [DateTime]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()

$knownPrices = @(
    @{ name='OxygenTank'; id='o_skill_oxygen_tank_01'; maxRank=10; shells=5; scrap=0 }
    @{ name='PlasmaDamage'; id='o_skill_plasma_damage_01'; maxRank=10; shells=15; scrap=0 }
    @{ name='ScrapValue'; id='o_skill_scrap_value'; maxRank=10; shells=25; scrap=0 }
    @{ name='BubbleDamage'; id='o_skill_bubble_damage_01'; maxRank=10; shells=5; scrap=0 }
    @{ name='JellyfishValue'; id='o_skill_jellyfish_value_01'; maxRank=10; shells=0; scrap=5 }
    @{ name='o_skill_store_slots_01'; id='o_skill_store_slots_01'; maxRank=1; shells=0; scrap=20; requires=@('o_skill_player_slots_01') }
    @{ name='o_skill_store_speed_01'; id='o_skill_store_speed_01'; maxRank=5; shells=0; scrap=10; requires=@('o_skill_store_slots_01') }
    @{ name='o_skill_scrap_increase'; id='o_skill_scrap_increase'; maxRank=10; shells=@(5,10,15,20,25,30,35,40,45,50); scrap=0; requires=@('o_skill_scrap_value') }
    @{ name='o_skill_oxygen_tank_02'; id='o_skill_oxygen_tank_02'; maxRank=10; shells=50; scrap=0; maxRequires=@{o_skill_oxygen_tank_01=10} }
    @{ name='Biodiversity'; id='o_skill_biodiversity_shallows'; maxRank=10; shells=0; scrap=@(5,10,15,20,25,30,35,40,45,50); requires=@('o_skill_jellyfish_value_01') }
    @{ name='JellyfishInsurance'; id='o_skill_jellyfish_insurance_01'; maxRank=1; shells=15; scrap=0; requires=@('o_skill_jellyfish_value_01','o_skill_scrap_value') }
    @{ name='PlasmaCharge'; id='o_skill_plasma_charge_01'; maxRank=5; shells=25; scrap=0; requires=@('o_skill_plasma_damage_01') }
    @{ name='PlasmaRange'; id='o_skill_plasma_range_01'; maxRank=1; shells=50; scrap=0; requires=@('o_skill_plasma_damage_01') }
    @{ name='PlasmaTank'; id='o_skill_plasma_tank_01'; maxRank=1; shells=50; scrap=0; requires=@('o_skill_deep_breath','o_skill_plasma_tool') }
    @{ name='BubbleSize'; id='o_skill_bubble_size_01'; maxRank=1; shells=0; scrap=50; requires=@('o_skill_bubble_damage_01') }
    @{ name='BubbleTank'; id='o_skill_bubble_tank_01'; maxRank=1; shells=0; scrap=50; requires=@('o_skill_deep_breath') }
    @{ name='o_skill_bubble_duration_01'; id='o_skill_bubble_duration_01'; maxRank=1; shells=0; scrap=100; requires=@('o_skill_bubble_size_01') }
    @{ name='o_skill_bubble_capacity_01'; id='o_skill_bubble_capacity_01'; maxRank=1; shells=0; scrap=100; requires=@('o_skill_bubble_tank_01') }
    @{ name='o_skill_jellyfish_value_rare_01'; id='o_skill_jellyfish_value_rare_01'; maxRank=1; shells=0; scrap=300; maxRequires=@{o_skill_jellyfish_value_01=10} }
    @{ name='BubbleDoppel'; id='o_skill_bubble_doppel_01'; maxRank=4; shells=0; scrap=100; requires=@('o_skill_bubble_damage_01') }
    @{ name='o_skill_chest_speed_01'; id='o_skill_chest_speed_01'; maxRank=1; shells=0; scrap=250; requires=@('o_skill_store_slots_01') }
    @{ name='Capacity'; id='o_skill_slot_capacity_01'; maxRank=1; shells=100; scrap=0; requires=@('o_skill_player_slots_01') }
    @{ name='DeepBreath'; id='o_skill_deep_breath'; maxRank=3; shells=@(10,100,1000); scrap=0; requires=@('o_skill_submarine') }
    @{ name='o_skill_plasma_capacity_01'; id='o_skill_plasma_capacity_01'; maxRank=1; shells=100; scrap=0; requires=@('o_skill_plasma_tank_01') }
    @{ name='o_skill_scrap_value_rare'; id='o_skill_scrap_value_rare'; maxRank=1; shells=300; scrap=0; maxRequires=@{o_skill_scrap_value=10} }
    @{ name='o_skill_bubble_speed_01'; id='o_skill_bubble_speed_01'; maxRank=5; shells=0; scrap=200; requires=@('o_skill_bubble_duration_01') }
    @{ name='o_skill_store_speed_02'; id='o_skill_store_speed_02'; maxRank=4; shells=0; scrap=200; maxRequires=@{o_skill_store_speed_01=5} }
    @{ name='o_skill_store_speed_03'; id='o_skill_store_speed_03'; maxRank=5; crystals=20; maxRequires=@{o_skill_store_speed_02=4} }
    @{ name='o_skill_jellyfish_value_rare_02'; id='o_skill_jellyfish_value_rare_02'; maxRank=1; crystals=1500; maxRequires=@{o_skill_jellyfish_value_02=10} }
    @{ name='LightFeet'; id='o_skill_movement_speed_01'; maxRank=4; shells=2000; requires=@('o_skill_jellyfish_insurance_01') }
    @{ name='o_skill_bubble_firerate_01'; id='o_skill_bubble_firerate_01'; maxRank=5; scrap=600; requires=@('o_skill_bubble_damage_02') }
    @{ name='o_skill_plasma_chain_number_01'; id='o_skill_plasma_chain_number_01'; maxRank=1; shells=300; scrap=0; requires=@('o_skill_plasma_damage_01') }
    @{ name='o_skill_plasma_damage_02'; id='o_skill_plasma_damage_02'; maxRank=10; shells=250; scrap=0; maxRequires=@{o_skill_plasma_damage_01=10} }
    @{ name='o_skill_slot_capacity_02'; id='o_skill_slot_capacity_02'; maxRank=1; shells=1500; scrap=0; requires=@('o_skill_slot_capacity_01') }
    @{ name='o_skill_oxygen_tank_03'; id='o_skill_oxygen_tank_03'; maxRank=10; shells=2000; scrap=0; maxRequires=@{o_skill_oxygen_tank_02=10} }
    @{ name='o_skill_plasma_chain_damage_01'; id='o_skill_plasma_chain_damage_01'; maxRank=5; shells=1500; scrap=0; requires=@('o_skill_plasma_chain_number_01') }
    @{ name='o_skill_crystal_value'; id='o_skill_crystal_value'; maxRank=10; shells=5000; scrap=0; maxRequires=@{o_skill_scrap_value_rare=1} }
    @{ name='o_skill_bubble_damage_02'; id='o_skill_bubble_damage_02'; maxRank=10; shells=0; scrap=250; maxRequires=@{o_skill_bubble_damage_01=10} }
    @{ name='o_skill_plasma_reload_01'; id='o_skill_plasma_reload_01'; maxRank=1; shells=500; scrap=0; requires=@('o_skill_plasma_tank_01','o_skill_plasma_capacity_01') }
)

$stockCatalog = $null
if ($UseStockCatalog) {
    $stockCatalog = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'skill-prices.original.json') | ConvertFrom-Json -AsHashtable
    $layout = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'skill-layout.original.json') | ConvertFrom-Json -AsHashtable
    if ($stockCatalog.executableSha256 -ne '62599F01A4CE4B8946FCC38827E6364539E31ABBED99B0828112E670B0C3925E' -or
        $stockCatalog.sourceDataSha256 -ne $layout.sourceSha256 -or $stockCatalog.nodes.Count -ne $layout.nodeCount) {
        throw 'The stock price catalog does not match the original Shelldiver build.'
    }
    # The later price assignments in these constructors belong to the demo.
    $steamPriceNodes = @(
        'o_skill_jellyfish_insurance_02', 'o_skill_movement_speed_01', 'o_skill_movement_speed_02',
        'o_skill_plasma_chain_number_02', 'o_skill_bubble_firerate_01', 'o_skill_bubble_doppel_01',
        'o_skill_plasma_range_02', 'o_skill_bubble_size_02', 'o_skill_bubble_penetration_01',
        'o_skill_store_speed_03', 'o_skill_agile_hands_01'
    )
    foreach ($id in $steamPriceNodes) {
        $node = $stockCatalog.nodes[$id]
        if ($node.status -eq 'variant' -and $node.baseRanks.Count -gt 0) {
            $node.status = 'constant'
            $node.ranks = $node.baseRanks
            $node.maxRank = $node.ranks.Count
        }
    }
}
$knownIds = @($knownPrices | ForEach-Object id)

function Read-SharedBytes([string]$Path) {
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    } catch [IO.IOException] {
        return
    }
    $memory = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($memory)
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $stream.Dispose()
    }
}

function Assert-CampaignActive {
    if ([IO.File]::Exists($stopPath)) {
        $signalBytes = Read-SharedBytes $stopPath
        if ($signalBytes) {
            $signal = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($signalBytes))
            if ($signal.requestedTicks -ge $startedUtc.Ticks) {
                throw [OperationCanceledException]::new('Shelldiver campaign stop requested.')
            }
        }
    }
}

function Get-Budget([int]$Minimum, [int]$Maximum) {
    Assert-CampaignActive
    $available = [Math]::Floor($TimeoutSeconds - $clock.Elapsed.TotalSeconds)
    if ($available -lt $Minimum) { throw 'The campaign time budget has been reached.' }
    return [int][Math]::Min($available, $Maximum)
}

function Read-CampaignSave {
    try {
        $raw = Read-SharedBytes $SavePath
        if (!$raw) { return }
        $text = [Text.Encoding]::UTF8.GetString($raw).Trim()
        if (!$text.StartsWith('{')) {
            $binary = [Convert]::FromHexString($text)
            if ($binary.Length -lt 16) { return }
            $length = [BitConverter]::ToInt32($binary, 12)
            if ($length -le 0 -or $length -ne ($binary.Length - 16)) { return }
            $text = [Text.Encoding]::UTF8.GetString($binary, 16, $length)
        }
        $save = ConvertFrom-Json -InputObject $text -AsHashtable
        if ($save.global) { $save = $save.global }
        if ($null -eq $save.shell_coins -or $null -eq $save.scrap_coins -or $null -eq $save.skills_saved) { return }
        $levels = ($save.skills_saved.Values | Measure-Object -Sum).Sum
        $wallet = @{}
        foreach ($currency in $walletFields.Keys) { $wallet[$currency] = [double]$save[$walletFields[$currency]] }
        return [pscustomobject]@{
            wallet = $wallet
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw))
            shellCoins = [double]$save.shell_coins
            scrapCoins = [double]$save.scrap_coins
            purchasedLevels = [int]$levels
            skills = $save.skills_saved
        }
    } catch {
        return
    }
}

function Wait-CampaignSave {
    $deadline = $clock.Elapsed.TotalSeconds + (Get-Budget 1 4)
    do {
        Assert-CampaignActive
        $save = Read-CampaignSave
        if ($save) { return $save }
        Start-Sleep -Milliseconds 40
    } while ($clock.Elapsed.TotalSeconds -lt $deadline)
    throw 'The original Shelldiver save could not be read.'
}

function Get-AffordablePlan($Save) {
    $wallet = $Save.wallet.Clone()
    $ranks = @{}
    foreach ($id in $Save.skills.Keys) { $ranks[$id] = [int]$Save.skills[$id] }
    foreach ($price in $knownPrices) {
        if ($price.requires -and ($price.requires | Where-Object { [int]$ranks[$_] -lt 1 })) { continue }
        if ($price.maxRequires -and ($price.maxRequires.Keys | Where-Object { [int]$ranks[$_] -lt $price.maxRequires[$_] })) { continue }
        $rank = [int]$ranks[$price.id]
        while ($rank -lt $price.maxRank) {
            $costs = @{}
            foreach ($currency in $walletFields.Keys) {
                if (!$price.ContainsKey($currency)) { continue }
                $amount = $price[$currency]
                $costs[$currency] = if ($amount -is [array]) { $amount[$rank] } else { $amount }
            }
            if ($costs.Keys | Where-Object { $null -eq $costs[$_] -or $wallet[$_] -lt $costs[$_] }) { break }
            @{ name=$price.name; id=$price.id; rank=$rank; costs=$costs; fromCatalog=$false }
            foreach ($currency in $costs.Keys) { $wallet[$currency] -= $costs[$currency] }
            ++$rank
        }
        $ranks[$price.id] = $rank
    }

    if (!$stockCatalog) { return }
    $saveForRareGlacialValue = [int]$ranks.o_skill_jellyfish_value_02 -ge 10 -and
        [int]$ranks.o_skill_jellyfish_value_rare_02 -eq 0
    $swampValueId = 'o_skill_jellyfish_value_rare_03'
    $reserveSwampValue = [int]$ranks.o_skill_jellyfish_value_03 -ge 10 -and [int]$ranks[$swampValueId] -eq 0
    $swampValuePrice = $stockCatalog.nodes[$swampValueId].ranks[0].price
    $mushroomValueId = 'o_skill_mushroom_value_rare'
    $reserveMushroomValue = $Save.purchasedLevels -ge 426 -and [int]$ranks.o_skill_mushroom_value -ge 10 -and
        [int]$ranks[$mushroomValueId] -eq 0
    $mushroomValuePrice = $stockCatalog.nodes[$mushroomValueId].ranks[0].price
    $magmaPlasmaId = 'o_skill_plasma_damage_06'
    $reserveMagmaPlasma = $Save.purchasedLevels -ge 475 -and [int]$ranks.o_skill_plasma_damage_05 -ge 10 -and
        [int]$ranks[$magmaPlasmaId] -eq 0
    $magmaPlasmaPrice = $stockCatalog.nodes[$magmaPlasmaId].ranks[0].price
    $cellphoneId = 'o_skill_cellphone'
    $reserveCellphone = $Save.purchasedLevels -ge 475 -and [int]$ranks.o_skill_submarine_storage -ge 1 -and
        [int]$ranks[$cellphoneId] -eq 0
    $cellphonePrice = $stockCatalog.nodes[$cellphoneId].ranks[0].price
    $candidates = foreach ($id in $stockCatalog.nodes.Keys) {
        if ($saveForRareGlacialValue -and $id -eq 'o_skill_biodiversity_glacial' -and
            [int]$ranks.o_skill_biodiversity_glacial -ge 4) { continue }
        $node = $stockCatalog.nodes[$id]
        $rank = [int]$ranks[$id]
        if ($id -in $knownIds -or $node.status -ne 'constant' -or $rank -ge $node.maxRank) { continue }
        $next = $node.ranks[$rank]
        if ($saveForRareGlacialValue -and $next.currency -eq 'crystals') { continue }
        if (!$next.currency -or !$wallet.ContainsKey($next.currency) -or $wallet[$next.currency] -lt $next.price) { continue }
        $firstMushroomValue = $id -eq 'o_skill_mushroom_value' -and $rank -eq 0
        $earlySwampShellValue = $id -eq 'o_skill_jellyfish_value_03' -and $ranks.o_skill_bubble_damage_05 -ge 5
        $priority = if ($reserveCellphone -and $id -eq $cellphoneId) { -3 }
            elseif ($id -in $swampValueId, $mushroomValueId -or ($reserveMagmaPlasma -and $id -eq $magmaPlasmaId)) { -2 }
            elseif ($id -eq 'o_skill_store_speed_06' -or ($rank -eq 0 -and $id -in
                'o_skill_bubble_damage_06', 'o_skill_bubble_firerate_02', 'o_skill_store_slots_03', 'o_skill_chest_speed_02')) { -1 }
            elseif ($firstMushroomValue -or $earlySwampShellValue) { 0 } else { 1 }
        [pscustomobject]@{id=$id; node=$node; nextPrice=$next.price; priority=$priority}
    }

    foreach ($candidate in ($candidates | Sort-Object priority, nextPrice, id)) {
        $id = $candidate.id
        $node = $candidate.node
        if (($node.needsAnyLevel -and ($node.needsAnyLevel | Where-Object { [int]$ranks[$_] -lt 1 })) -or
            ($node.needsMaxLevel -and ($node.needsMaxLevel | Where-Object {
                $parent = $stockCatalog.nodes[$_]
                $parentPrice = $knownPrices | Where-Object id -eq $_ | Select-Object -First 1
                $maximum = if ($parent.status -eq 'constant') { $parent.maxRank } elseif ($parentPrice) { $parentPrice.maxRank }
                !$maximum -or [int]$ranks[$_] -lt $maximum
            }))) { continue }
        $rank = [int]$ranks[$id]
        $endRank = if ($rank -gt 0) { $node.maxRank } else { 1 }
        while ($rank -lt $endRank) {
            $next = $node.ranks[$rank]
            if (!$next.currency -or !$wallet.ContainsKey($next.currency) -or $wallet[$next.currency] -lt $next.price) { break }
            if ($reserveSwampValue -and $id -ne $swampValueId -and $next.currency -eq 'mushrooms' -and
                $wallet.mushrooms - $next.price -lt $swampValuePrice) { break }
            if ($reserveMushroomValue -and $id -ne $mushroomValueId -and $next.currency -eq 'shells' -and
                $wallet.shells - $next.price -lt $mushroomValuePrice) { break }
            if ($reserveMagmaPlasma -and $id -ne $magmaPlasmaId -and $next.currency -eq 'shells' -and
                $wallet.shells - $next.price -lt $magmaPlasmaPrice) { break }
            if ($reserveCellphone -and $id -ne $cellphoneId -and $next.currency -eq 'crystals' -and
                $wallet.crystals - $next.price -lt $cellphonePrice) { break }
            $costs = @{}
            $costs[$next.currency] = $next.price
            @{name=$id; id=$id; rank=$rank; costs=$costs; fromCatalog=$true}
            if ($id -eq $swampValueId) { $reserveSwampValue = $false }
            if ($id -eq $mushroomValueId) { $reserveMushroomValue = $false }
            if ($id -eq $magmaPlasmaId) { $reserveMagmaPlasma = $false }
            if ($id -eq $cellphoneId) { $reserveCellphone = $false }
            $wallet[$next.currency] -= $next.price
            ++$rank
        }
        $ranks[$id] = $rank
    }
}

if (!(Get-Command -Name $session).Parameters.ContainsKey('BatchSettlement')) {
    throw 'The current session script does not expose -BatchSettlement.'
}

$gamePid = $null
$initialSave = Wait-CampaignSave
$latestSave = $initialSave
$receipts = [Collections.Generic.List[object]]::new()
$phase = 'completed'
$errorMessage = $null
$errorStack = $null
$priorStopPath = $env:SHELLDIVER_SESSION_STOP_PATH
$priorStartedTicks = $env:SHELLDIVER_SESSION_STARTED_TICKS
$env:SHELLDIVER_SESSION_STOP_PATH = $stopPath
$env:SHELLDIVER_SESSION_STARTED_TICKS = [string]$startedUtc.Ticks

try {
    $cycleLimit = if ($Rounds -eq 0) { 1 } else { $Cycles }
    $secondsPerRound = [Math]::Max(43, $HarvestSeconds + 23)
    $expeditionBudget = [Math]::Max(175, 40 + $secondsPerRound * $Rounds)
    for ($cycle = 1; $cycle -le $cycleLimit; $cycle++) {
        if ($StopAtRank -and $latestSave.purchasedLevels -ge $StopAtRank) { break }
        $selectedKind = $Kind
        if ($Kind -eq 'Alternate') { $selectedKind = if ($cycle % 2 -eq 1) { 'Resource' } else { 'Jellyfish' } }
        $receipt = [pscustomobject]@{
            cycle = $cycle
            kind = $selectedKind
            startedUtc = [DateTime]::UtcNow.ToString('o')
            phase = 'expeditions'
            before = $latestSave
            expedition = $null
            followUpExpedition = $null
            beforeUpgrades = $null
            alchemy = $null
            plannedSkills = @()
            purchases = @()
            unavailableStockNodes = @()
            after = $null
            finishedUtc = $null
        }
        $receipts.Add($receipt)
        if ($Rounds -eq 0) {
            $settled = & $session -Action Settle -Mailbox $Mailbox -SavePath $SavePath -TimeoutSeconds (Get-Budget 20 175)
            $receipt.expedition = [pscustomobject]@{
                pid=$settled.pid; room=$settled.room; roundsCompleted=0
                nativeBalanceVerified=($null -ne $settled.nativeSaveAfter)
                verifiedSaveAfter=$settled.nativeSaveAfter; elapsedMs=$settled.commandElapsedMs
            }
        } else {
            $receipt.expedition = & $session -Action Run -Kind $selectedKind -Rounds $Rounds -Depth $Depth -BatchSettlement -DeferShopPayout:([bool]$FollowUpResourceDepth) -PlasmaHoldFrames $PlasmaHoldFrames `
                -Mailbox $Mailbox -SavePath $SavePath -HarvestSeconds $HarvestSeconds -ReturnOxygen $ReturnOxygen -TimeoutSeconds (Get-Budget 20 $expeditionBudget)
        }
        if (!$gamePid) { $gamePid = $receipt.expedition.pid }
        if (!$gamePid -or $receipt.expedition.pid -ne $gamePid -or $receipt.expedition.room -ne 'rm_main_island') {
            throw 'The expedition batch did not finish in the same resident island session.'
        }
        if (!$receipt.expedition.nativeBalanceVerified -or !$receipt.expedition.verifiedSaveAfter.sha256) {
            throw 'The expedition batch did not verify its settlement save.'
        }

        $verified = $receipt.expedition.verifiedSaveAfter
        if ($FollowUpResourceDepth) {
            $receipt.phase = 'mining-before-payout'
            $followUpArguments = @{
                Action='Run'; Kind='Resource'; Rounds=$Rounds; Depth=$FollowUpResourceDepth; BatchSettlement=$true
                Mailbox=$Mailbox; SavePath=$SavePath; HarvestSeconds=$HarvestSeconds; ReturnOxygen=$ReturnOxygen
                PlasmaHoldFrames=$PlasmaHoldFrames; TimeoutSeconds=(Get-Budget 20 $expeditionBudget)
            }
            $receipt.followUpExpedition = & $session @followUpArguments
            $followUp = $receipt.followUpExpedition
            if ($followUp.pid -ne $gamePid -or $followUp.room -ne 'rm_main_island' -or
                !$followUp.nativeBalanceVerified -or !$followUp.verifiedSaveAfter.sha256) {
                throw 'The mining and shop payout did not finish in the same verified island session.'
            }
            $verified = $followUp.verifiedSaveAfter
        }
        $saved = Wait-CampaignSave
        if ($walletFields.Keys | Where-Object { $saved.wallet[$_] -ne $verified.wallet[$_] }) {
            throw 'The native balances changed after expedition settlement.'
        }
        $alchemyBudget = [decimal]100000000000000 * $pendingExchanges
        if ($pendingExchanges -gt 0 -and [int]$saved.skills.o_skill_alchemy_station -ge 1 -and
            [decimal]$saved.wallet.shells -ge $alchemyBudget) {
            $receipt.phase = 'alchemy'
            $receipt.alchemy = & $alchemy -Vials $pendingExchanges -Mailbox $Mailbox -SavePath $SavePath `
                -TimeoutSeconds (Get-Budget 10 900)
            $exchanged = $receipt.alchemy
            $afterExchange = Wait-CampaignSave
            if ($exchanged.pid -ne $gamePid -or !$exchanged.nativeSaveVerified -or
                $exchanged.exchangesCompleted -ne $pendingExchanges -or $exchanged.shellsSpent -ne $alchemyBudget -or
                [decimal]$afterExchange.wallet.shells -ne [decimal]$saved.wallet.shells - $alchemyBudget -or
                $afterExchange.wallet.lifeVials -ne $saved.wallet.lifeVials + $exchanged.vialsCollected) {
                throw 'The campaign could not reconcile the native Life Vial exchange.'
            }
            $saved = $afterExchange
            $pendingExchanges = 0
        }
        $receipt.beforeUpgrades = $saved
        $plan = @(Get-AffordablePlan $saved)
        if ($plan.Count) {
            $receipt.phase = 'upgrades'
            $receipt.plannedSkills = @($plan | ForEach-Object name)
            $upgradeBudget = [int][Math]::Min(90, [Math]::Max(30, 8 + 3.5 * $plan.Count))
            $result = & $upgrade -Skill $receipt.plannedSkills -Mailbox $Mailbox -SavePath $SavePath -KeepCameraPosition `
                -TimeoutSeconds (Get-Budget 8 $upgradeBudget)
            $receipt.purchases = @($result.purchases)
            if ($result.pid -ne $gamePid) { throw 'The game restarted during native upgrades.' }
            if ($receipt.purchases.Count -ne $plan.Count) { throw 'Not every planned upgrade returned a native receipt.' }

            $wallet = $saved.wallet.Clone()
            $expectedRanks = @{}
            for ($index = 0; $index -lt $plan.Count; $index++) {
                $entry = $plan[$index]
                $actual = $receipt.purchases[$index]
                if ($actual.skill -ne $entry.name) { throw 'Upgrade receipt points to a different native skill.' }
                if ($entry.fromCatalog -and !$actual.purchased -and $actual.before -eq $actual.after -and
                    !($actual.spent.Values | Where-Object { $_ -ne 0 })) {
                    $receipt.unavailableStockNodes += $entry.id
                    continue
                }
                if (!$actual.purchased -or $actual.after -ne ($actual.before + 1) -or
                    (!$entry.fromCatalog -and $actual.before -ne $entry.rank)) {
                    throw "Native purchase did not match the planned rank for $($entry.name)."
                }
                $costs = $entry.costs
                if ($entry.fromCatalog) {
                    $next = $stockCatalog.nodes[$entry.id].ranks[$actual.before]
                    $costs = @{}
                    $costs[$next.currency] = $next.price
                }
                foreach ($currency in $walletFields.Keys) {
                    $expected = [double]$costs[$currency]
                    if ([double]$actual.spent[$currency] -ne $expected) {
                        throw "Native purchase did not match the stock $currency price for $($entry.name)."
                    }
                    $wallet[$currency] -= $expected
                }
                $expectedRanks[$entry.id] = $actual.after
            }
            $latestSave = Wait-CampaignSave
            if ($walletFields.Keys | Where-Object { $latestSave.wallet[$_] -ne $wallet[$_] }) {
                throw 'The saved balances did not reconcile with native purchase receipts.'
            }
            foreach ($id in $expectedRanks.Keys) {
                if ([int]$latestSave.skills[$id] -ne $expectedRanks[$id]) {
                    throw "The native save did not contain the purchased rank for $id."
                }
            }
        } else {
            $latestSave = $saved
        }

        $receipt.phase = 'completed'
        $receipt.after = $latestSave
        $receipt.finishedUtc = [DateTime]::UtcNow.ToString('o')
        Assert-CampaignActive
    }
} catch {
    $phase = if ($_.Exception.GetBaseException() -is [OperationCanceledException]) { 'stopped' } else { 'blocked' }
    $errorMessage = $_.Exception.Message
    $errorStack = $_.ScriptStackTrace
    $latestSave = Read-CampaignSave
    if ($receipts.Count -gt 0 -and $receipts[$receipts.Count - 1].phase -ne 'completed') {
        $last = $receipts[$receipts.Count - 1]
        $last.after = $latestSave
        $last.finishedUtc = [DateTime]::UtcNow.ToString('o')
    }
} finally {
    $env:SHELLDIVER_SESSION_STOP_PATH = $priorStopPath
    $env:SHELLDIVER_SESSION_STARTED_TICKS = $priorStartedTicks
}
return [pscustomobject]@{
    phase = $phase
    error = $errorMessage
    errorStack = $errorStack
    stopAtRank = $StopAtRank
    reachedRank = [bool]($StopAtRank -and $latestSave.purchasedLevels -ge $StopAtRank)
    pendingExchanges = $pendingExchanges
    pid = $gamePid
    hostPid = $PID
    startedUtc = $startedUtc.ToString('o')
    finishedUtc = [DateTime]::UtcNow.ToString('o')
    elapsedMs = $clock.ElapsedMilliseconds
    cyclesCompleted = @($receipts | Where-Object phase -eq 'completed').Count
    roundsCompleted = [int](($receipts | ForEach-Object {
        [int]$_.expedition.roundsCompleted + [int]$_.followUpExpedition.roundsCompleted
    } | Measure-Object -Sum).Sum)
    nativeSaveBefore = $initialSave
    nativeSaveAfter = $latestSave
    cycles = $receipts
}
