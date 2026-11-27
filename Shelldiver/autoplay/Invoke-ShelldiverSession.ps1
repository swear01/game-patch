[CmdletBinding()]
param(
    [ValidateSet('Run', 'Status', 'Stop', 'Launch', 'FinishResult', 'RetryResult', 'Settle', 'CollectShopCredit')]
    [string]$Action = 'Run',

    [switch]$ResultVerified,

    [switch]$SettleAfterResult,

    [ValidateRange(1, 12)]
    [int]$Rounds = 1,

    [ValidateSet('Jellyfish', 'Resource', 'Mixed')]
    [string]$Kind = 'Jellyfish',

    [ValidateSet(100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200)]
    [int]$Depth = 100,

    [switch]$BatchSettlement,
    [switch]$DeferShopPayout,

    [switch]$HoldResult,

    [switch]$ReturnImmediately,

    [switch]$FillBackpack,

    [switch]$ReturnBetweenRounds,

    [ValidateRange(0, 6)]
    [int]$StopAfterEmptyResourceRounds,

    [ValidateRange(1, 35)]
    [int]$HarvestSeconds = 6,

    [ValidateRange(46, 200)]
    [int]$PlasmaHoldFrames = 200,

    [ValidateSet('West', 'East')]
    [string]$MagmaMineSector = 'West',

    [ValidateRange(35, 95)]
    [int]$ReturnOxygen = 65,

    [switch]$StartAtDialog,

    [ValidateRange(0.0, 1.0)]
    [double]$ReturnConfirmX = 0.4375,

    [ValidateRange(0.0, 1.0)]
    [double]$ReturnConfirmY = (196.0 / 360),

    [ValidateRange(20, 600)]
    [int]$TimeoutSeconds = 90,

    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),

    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json')
)

$ErrorActionPreference = 'Stop'
if ($Action -eq 'Run' -and $Depth -in 1100,1200 -and !('ShelldiverDynamicRoute' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'ShelldiverDynamicRoute.cs')
}
if (!$PSBoundParameters.ContainsKey('FillBackpack') -and $Action -eq 'Run' -and $Depth -in 1100,1200 -and
    $Kind -eq 'Jellyfish' -and !$ReturnImmediately) { $FillBackpack=$true }
if ($FillBackpack -and ($Action -ne 'Run' -or $Depth -notin 1100,1200 -or $Kind -ne 'Jellyfish' -or $ReturnImmediately)) {
    throw 'Filling the backpack requires a normal 1100m or 1200m Jellyfish run.'
}
$sessionDeadline = if ($FillBackpack) { [double]::PositiveInfinity } else { [double]$TimeoutSeconds }
if ($StopAfterEmptyResourceRounds -gt 0 -and ($Action -ne 'Run' -or $Kind -ne 'Resource' -or $HoldResult -or $ReturnImmediately)) {
    throw 'Stopping after empty resource rounds requires an active Resource batch with native settlement.'
}
if ($MagmaMineSector -eq 'East' -and ($Action -ne 'Run' -or $Depth -ne 1000 -or $Kind -ne 'Resource')) {
    throw 'The East mining sector is available for 1000m Resource expeditions.'
}
if ($Action -eq 'Run' -and $Kind -eq 'Mixed' -and $Depth -notin 700, 800, 900) {
    throw 'Mixed harvesting is supported at 700, 800 and 900 meters.'
}
. (Join-Path $PSScriptRoot 'ShelldiverMailbox.ps1')
. (Join-Path $PSScriptRoot 'ShelldiverCatchFlow.ps1')
$walletFields = @{
    shells='shell_coins'; scrap='scrap_coins'; crystals='crystal_coins'
    mushrooms='mushroom_coins'; obsidian='obsidian_coins'; lifeVials='flask_coins'
}
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$island = Join-Path $PSScriptRoot 'Invoke-ShelldiverIsland.ps1'
$dive = Join-Path $PSScriptRoot 'Invoke-ShelldiverDive.ps1'
$timer = [Diagnostics.Stopwatch]::StartNew()
$gamePid = $null
$payoutSaveRuns = 0
$shopChestHoldSteps = 120
$regions = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'ShelldiverRegions.psd1')
$region = $regions[$Depth]
$diveRooms = @($regions.Values | ForEach-Object room)
$Mailbox = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Mailbox)
$sessionPath = Join-Path $Mailbox 'session.json'
$stopPath = Join-Path $Mailbox 'session.stop.json'
$startedUtc = [DateTime]::UtcNow
$startedTicks = $startedUtc.Ticks
$hasReturnConfirmX = $PSBoundParameters.ContainsKey('ReturnConfirmX')
$hasReturnConfirmY = $PSBoundParameters.ContainsKey('ReturnConfirmY')

function Read-SessionFile([string]$Path) {
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return
    }
    try {
        $reader = [IO.StreamReader]::new($stream)
        try { return (ConvertFrom-Json -InputObject $reader.ReadToEnd()) } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Write-SessionFile([string]$Path, $Value) {
    $null = [IO.Directory]::CreateDirectory($Mailbox)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8 -Compress))
        Publish-ShelldiverMailboxFile $temporary $Path
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Set-SessionPhase([string]$Phase, [string]$Message = '') {
    Write-SessionFile $sessionPath @{
        action = $Action
        phase = $Phase
        hostPid = $PID
        gamePid = $gamePid
        startedTicks = $startedTicks
        startedUtc = $startedUtc.ToString('o')
        elapsedMs = $timer.ElapsedMilliseconds
        updatedUtc = [DateTime]::UtcNow.ToString('o')
        message = $Message
        lastDive = $script:latestDivePerformance
    }
}

function Get-StageSeconds([int]$Minimum, [int]$Maximum) {
    $signal = Read-SessionFile $stopPath
    if ($signal -and $signal.requestedTicks -ge $startedTicks) {
        throw [OperationCanceledException]::new('Shelldiver session stop requested.')
    }
    $available = [Math]::Floor($sessionDeadline - $timer.Elapsed.TotalSeconds)
    if ($available -lt $Minimum) { throw 'The Shelldiver batch has reached its time budget.' }
    return [int][Math]::Min($available, $Maximum)
}

function Read-SessionSnapshot {
    $state = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 3)
    if ($gamePid -and $state.pid -ne $gamePid) { throw 'Shelldiver restarted during the batch.' }
    if ($state.room -notin ('rm_logo', 'rm_main_menu', 'rm_main_island' + $diveRooms)) {
        throw "The Shelldiver batch stopped on an unexpected screen in '$($state.room)'."
    }
    if (!$state.inputReady -or ($state.inputError -and $state.inputError -ne 'Could not publish the game mailbox response.')) {
        throw "The native input endpoint is not ready. $($state.inputError)"
    }
    return $state
}

function Wait-SessionSnapshot([scriptblock]$Condition, [string]$Expected, [int]$Seconds = 4) {
    $deadline = $timer.Elapsed.TotalSeconds + (Get-StageSeconds 1 $Seconds)
    do {
        $state = Read-SessionSnapshot
        if (& $Condition $state) { return $state }
        Start-Sleep -Milliseconds 25
    } while ($timer.Elapsed.TotalSeconds -lt $deadline)
    throw "Timed out waiting for $Expected."
}

function Get-NativeShopSpace($PlayerInventory, $ShopInventory) {
    if (!$ShopInventory -or $ShopInventory.slot_capacity -le 0 -or $null -eq $ShopInventory.slots) { return }
    $cap = [int]$ShopInventory.slot_capacity
    $freeByType = @{}
    $emptySlots = [Math]::Max(0,[int]$ShopInventory.slot_number - @($ShopInventory.slots).Count)
    foreach ($slot in $ShopInventory.slots) {
        if ($slot.quantity -eq 0) { ++$emptySlots; continue }
        if ($slot.quantity -lt 0) { continue }
        $key = '{0}:{1}' -f $slot.type,$slot.id
        $freeByType[$key] += [Math]::Max(0,$cap-[int]$slot.quantity)
    }
    $transferable = 0
    foreach ($slot in $PlayerInventory.slots) {
        if ($slot.quantity -le 0 -or $slot.type -notin 0,1,2,3) { continue }
        $key = '{0}:{1}' -f $slot.type,$slot.id
        $requested = [int]$slot.quantity
        $need = [Math]::Max(0,$requested-[int]$freeByType[$key])
        $newSlots = [int][Math]::Min($emptySlots,[Math]::Ceiling($need/[double]$cap))
        $emptySlots -= $newSlots
        $freeByType[$key] += $newSlots*$cap
        $accepted = [Math]::Min($requested,[int]$freeByType[$key])
        $freeByType[$key] -= $accepted
        $transferable += $accepted
    }
    return $transferable
}

function Get-NativeBackpackSpace($Inventory) {
    if (!$Inventory -or $Inventory.slot_number -le 0 -or $Inventory.slot_capacity -le 0 -or
        $Inventory.slot_number -ne [int]$Inventory.slot_number -or
        $Inventory.slot_capacity -ne [int]$Inventory.slot_capacity -or $null -eq $Inventory.slots) { return }
    $slotCount = [int]$Inventory.slot_number
    $slotCapacity = [int]$Inventory.slot_capacity
    $emptySlots = $slotCount - @($Inventory.slots).Count
    if ($emptySlots -lt 0) { return }
    $partiallyEmpty = @{}
    foreach ($slot in $Inventory.slots) {
        if ($null -eq $slot.quantity -or $slot.quantity -lt 0 -or $slot.quantity -gt $slotCapacity -or
            $slot.quantity -ne [int]$slot.quantity) { return }
        if ($slot.quantity -eq 0) { ++$emptySlots; continue }
        if ($null -eq $slot.id -or $slot.id -notin (0..11) -or $slot.type -notin (0..3)) { return }
        $key = '{0}:{1}' -f [int]$slot.id,[int]$slot.type
        $partiallyEmpty[$key] += $slotCapacity - [int]$slot.quantity
    }
    $spaceByType = @{}
    foreach ($species in 0..11) {
        foreach ($rarity in 0..3) {
            $key = '{0}:{1}' -f $species,$rarity
            $spaceByType[$key] = $slotCapacity*$emptySlots + [int]$partiallyEmpty[$key]
        }
    }
    return @{slotCapacity=$slotCapacity; emptySlots=$emptySlots; spaceByType=$spaceByType}
}

function Get-SavedFishInventory($Inventory) {
    if (!$Inventory -or $null -eq $Inventory.slots) { return }
    $typed = @{}
    $species = @{}
    $count = 0L
    foreach ($slot in $Inventory.slots) {
        if ($slot.quantity -le 0) { continue }
        if ($null -eq $slot.id -or $slot.id -lt 0 -or $slot.type -notin 0,1,2,3 -or
            $slot.quantity -ne [long]$slot.quantity) { return }
        $id = [int]$slot.id
        $qty = [long]$slot.quantity
        $typed["$id,$([int]$slot.type)"] += $qty
        $species[[string]$id] += $qty
        $count += $qty
    }
    return @{typed=$typed;species=$species;count=$count}
}

function Get-SavedTransmutableCount($Inventory, [int]$OutputType) {
    $count = 0L
    foreach ($key in $Inventory.typed.Keys) {
        if ([int]($key.Split(',')[1]) -lt $OutputType) { $count += $Inventory.typed[$key] }
    }
    return $count
}

function Get-SavedCatchPipeline($Save) {
    $flow = [ordered]@{}
    $species = @{}
    $count = 0L
    foreach ($name in 'player_inventory','submarine_inventory','transmutator_inventory_in','transmutator_inventory_out','store_inventory') {
        $part = Get-SavedFishInventory $Save._all_inventories.$name
        if (!$part) { return }
        $flow[$name] = $part
        $count += $part.count
        foreach ($id in $part.species.Keys) { $species[$id] += $part.species[$id] }
    }
    return @{inventories=$flow;species=$species;count=$count}
}

function Read-NativeSave {
    try {
        $raw = [IO.File]::ReadAllBytes($SavePath)
        $text = [Text.Encoding]::UTF8.GetString($raw).Trim()
        if (!$text.StartsWith('{')) {
            $binary = [Convert]::FromHexString($text)
            if ($binary.Length -lt 16) { return }
            $length = [BitConverter]::ToInt32($binary, 12)
            if ($length -le 0 -or $length -gt ($binary.Length - 16)) { return }
            $text = [Text.Encoding]::UTF8.GetString($binary, 16, $length)
        }
        $save = ConvertFrom-Json -InputObject $text
    } catch {
        return
    }
    if ($save.global) { $save = $save.global }
    if ($null -eq $save.shell_coins -or $null -eq $save.scrap_coins) { return }

    $inventory = $save._all_inventories.player_inventory
    $packSpace = Get-NativeBackpackSpace $inventory
    $jellyfish = $null
    $capacity = $null
    if ($inventory) {
        $jellyfish = ($inventory.slots | Where-Object { $_.quantity -gt 0 -and $_.type -in 0, 1, 2, 3 } |
            Measure-Object -Property quantity -Sum).Sum
        if ($null -eq $jellyfish) { $jellyfish = 0 }
        if ($inventory.slot_number -gt 0 -and $inventory.slot_capacity -gt 0) {
            $capacity = [int]$inventory.slot_number * [int]$inventory.slot_capacity
        }
    }
    $submarineInventory = $save._all_inventories.submarine_inventory
    $submarineJellyfish = if ($submarineInventory) {
        ($submarineInventory.slots | Where-Object { $_.quantity -gt 0 -and $_.type -in 0, 1, 2, 3 } |
            Measure-Object -Property quantity -Sum).Sum
    }
    $shopInventory = $save._all_inventories.store_inventory
    $queued = if ($shopInventory) {
        ($shopInventory.slots | Measure-Object -Property quantity -Sum).Sum
    }
    $storageAutoOutput = [int]$save.skills_saved.o_skill_storage_auto_output -ge 1
    $stationAutoOutput = [int]$save.skills_saved.o_skill_transmutator_auto_output -ge 1
    $stationReady = $save.jellyfish_transmutator_available -eq $true -and [int]$save.skills_saved.o_skill_jellyfish_transmutator -ge 1
    $outputType = if ($stationReady) {
        if ([int]$save.skills_saved.o_skill_transmutator_golden -ge 1) { 2 } else { 1 }
    } else { 0 }
    $catchPipeline = if ($storageAutoOutput) { Get-SavedCatchPipeline $save }
    $playerFish = if ($catchPipeline) { $catchPipeline.inventories.player_inventory } elseif ($outputType) { Get-SavedFishInventory $inventory }
    $wallet = @{}
    foreach ($currency in $walletFields.Keys) { $wallet[$currency] = [double]$save.($walletFields[$currency]) }
    $rangeI = [Math]::Clamp([int]$save.skills_saved.o_skill_plasma_range_01, 0, 1)
    $rangeII = [Math]::Clamp([int]$save.skills_saved.o_skill_plasma_range_02, 0, 1)
    # Stock beam reach starts at the 32px muzzle. Keep 8px outside the aim limit in reserve.
    $rangeIII = [Math]::Clamp([int]$save.skills_saved.o_skill_plasma_range_03, 0, 1)
    $rangeIV = [Math]::Clamp([int]$save.skills_saved.o_skill_plasma_range_04, 0, 1)
    $chargeI = [Math]::Clamp([int]$save.skills_saved.o_skill_plasma_charge_01, 0, 5)
    $chargeII = [Math]::Clamp([int]$save.skills_saved.o_skill_plasma_charge_02, 0, 5)
    $ultraCharge = [Math]::Clamp([int]$save.skills_saved.o_skill_plasma_ultra_charge, 0, 1)
    $magmaPlasmaChargeFrames = [int][Math]::Ceiling(140.0 / (1 + .20 * $chargeI + .40 * $chargeII + 7 * $ultraCharge))
    $magmaPlasmaAimRange = [int](64 * (1 + .25 * $rangeI + .50 * $rangeII + .75 * $rangeIII + 1.25 * $rangeIV) + 24)
    return [pscustomobject]@{
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw))
        wallet = $wallet
        shellCoins = $save.shell_coins
        storeShellCoins = $save.store_shell_coins
        storeQueuedJellyfish = $queued
        storeJellyfishCapacity = [int]$shopInventory.slot_number * [int]$shopInventory.slot_capacity
        storeCompatibleJellyfishSpace = Get-NativeShopSpace $inventory $shopInventory
        scrapCoins = $save.scrap_coins
        playerJellyfish = $jellyfish
        playerJellyfishCapacity = $capacity
        playerJellyfishSlotCapacity = $packSpace.slotCapacity
        playerJellyfishEmptySlots = $packSpace.emptySlots
        playerJellyfishSpaceByType = $packSpace.spaceByType
        playerRedJellyfishCompatibleSpace = if ($packSpace) { $packSpace.spaceByType['11:0'] }
        submarineJellyfish = [int]$submarineJellyfish
        catchPipeline = $catchPipeline
        storageAutoOutput = $storageAutoOutput
        transmutatorAutoOutput = $stationAutoOutput
        transmutatorOutputType = $outputType
        playerTransmutable = Get-SavedTransmutableCount $playerFish $outputType
        submarineTransmutable = Get-SavedTransmutableCount $catchPipeline.inventories.submarine_inventory $outputType
        transmutatorInputJellyfish = $catchPipeline.inventories.transmutator_inventory_in.count
        transmutatorOutputJellyfish = $catchPipeline.inventories.transmutator_inventory_out.count
        submarineJellyfishCapacity = [int]$submarineInventory.slot_number * [int]$submarineInventory.slot_capacity
        submarineBubbleOwned = [int]$save.skills_saved.o_skill_submarine_recover -ge 1
        submarineAmmoBubbleOwned = [int]$save.skills_saved.o_skill_submarine_recover_all -ge 1
        magmaBubblePenetration = 1.0 + .1*[int]$save.skills_saved.o_skill_bubble_penetration_01 +
            .6*[int]$save.skills_saved.o_skill_bubble_penetration_02
        magmaBubbleProjectileSpeed = 4.0*(1.0 + .2*[int]$save.skills_saved.o_skill_bubble_speed_01 +
            .5*[int]$save.skills_saved.o_skill_bubble_speed_02)
        magmaBubbleProjectileLifetime = 30*(1+[int]$save.skills_saved.o_skill_bubble_duration_01)
        magmaPlasmaAimRange = $magmaPlasmaAimRange
        magmaPlasmaChargeFrames = $magmaPlasmaChargeFrames
        magmaShockFrequency = [int]$save.skills_saved.o_skill_shock_frequency -ge 1
        magmaShockResistance = [int]$save.skills_saved.o_skill_shock_resistance_01 -ge 1
        magmaShockResistanceII = [int]$save.skills_saved.o_skill_shock_resistance_10 -ge 1
        showRestartButton = [bool]$save.show_restart_button
    }
}

function Invoke-RegionClick($State, [double]$GuiX, [double]$GuiY, [switch]$ConfirmsDive, [string]$ExpectedRoom) {
    if ($State.room -ne 'rm_main_island' -or $State.flags.transitioning -or !$State.guiPointer.buttonHooks) {
        throw 'The island is not ready for a submarine dialog click.'
    }
    $before = $State.guiPointer.buttonReads
    $params = @{x = $GuiX; y = $GuiY; button = 1; holdFrames = 1} | ConvertTo-Json -Compress
    $ack = & $control -Action click -ParametersJson $params -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 3)
    if ($null -eq $ack.frame) { throw 'The region dialog click did not report its acknowledgement frame.' }
    $clicked = Wait-SessionSnapshot {
        param($sample)
        if ($ConfirmsDive) {
            return $sample.room -eq $ExpectedRoom -and $sample.scene.player.oxygen -gt 0 -and
                $sample.scene.submarineLeave.event -like '*_Step_*' -and
                $sample.frame - $sample.scene.submarineLeave.frame -le 45
        }
        $sample.room -eq 'rm_main_island' -and $sample.frame -gt ($ack.frame + 9) -and
            !$sample.guiPointer.active -and $sample.guiPointer.buttonReads -gt $before
    } 'the native region dialog to handle its click'
    if ($ConfirmsDive) {
        $clicked | Add-Member -NotePropertyName autoplayBeforeEntryFrame -NotePropertyValue ([long]$ack.frame)
    }
    return $clicked
}

function Test-NativeShopPricingProgress($Progress, $Sample, $Saved) {
    $now = $timer.Elapsed.TotalSeconds
    $queued = $Saved.storeQueuedJellyfish
    $visible = $Sample.inventories.store.total
    $purse = $Sample.numbers.store_shell_coins
    if (($null -ne $queued -and $null -ne $Progress.queued -and $queued -lt $Progress.queued) -or
        ($null -ne $visible -and $null -ne $Progress.visible -and $visible -lt $Progress.visible) -or
        ($null -ne $purse -and $null -ne $Progress.purse -and $purse -gt $Progress.purse)) {
        $Progress.lastActivity = $now
    }
    if ($null -ne $queued) { $Progress.queued = $queued }
    if ($null -ne $visible) { $Progress.visible = $visible }
    if ($null -ne $purse) { $Progress.purse = $purse }
    return $now -lt $Progress.lastActivity + 30
}

function Wait-ExpectedNativeSave($State, [int]$Seconds = 8, [scriptblock]$Condition, [switch]$WatchShopPricing, [switch]$AllowConcurrentShopPricing) {
    $deadline = $timer.Elapsed.TotalSeconds + (Get-StageSeconds 1 $Seconds)
    $balance = $State
    $stableSamples = 0
    $pricing = if ($WatchShopPricing) { @{lastActivity=$timer.Elapsed.TotalSeconds} }
    do {
        $sample = Read-SessionSnapshot
        if ($sample.room -ne 'rm_main_island') { throw 'Native settlement moved out of the island before verification.' }
        if ($sample.frame -gt $balance.frame) {
            if ($sample.numbers.shell_coins -eq $balance.numbers.shell_coins -and
                $sample.numbers.scrap_coins -eq $balance.numbers.scrap_coins -and
                ($AllowConcurrentShopPricing -or $sample.numbers.store_shell_coins -eq $balance.numbers.store_shell_coins)) {
                ++$stableSamples
            } else {
                $stableSamples = 0
            }
            $balance = $sample
        }
        $save = Read-NativeSave
        $walletMatches = $save -and !($walletFields.Keys | Where-Object {
            [double]$balance.numbers.($walletFields[$_]) -ne $save.wallet[$_]
        })
        if ($stableSamples -ge 1 -and $walletMatches -and
            $save.shellCoins -eq $balance.numbers.shell_coins -and $save.scrapCoins -eq $balance.numbers.scrap_coins -and
            ($AllowConcurrentShopPricing -or $null -eq $save.storeShellCoins -or $save.storeShellCoins -eq $balance.numbers.store_shell_coins) -and
            (!$Condition -or (& $Condition $balance $save))) {
            return [pscustomobject]@{state=$balance; save=$save}
        }
        if ($pricing -and !(Test-NativeShopPricingProgress $pricing $balance $save)) { break }
        Start-Sleep -Milliseconds 50
    } while ($timer.Elapsed.TotalSeconds -lt $deadline)
    return [pscustomobject]@{state=$balance; save=$null}
}

function Open-SessionRegionDialog($State) {
    for ($approach = 1; $approach -le 3; ++$approach) {
        $current = Read-SessionSnapshot
        $travel = $current.scene.submarineTravel
        if ($null -eq $travel.xstart -or !$travel.can_be_used) { throw 'The native submarine entrance is unavailable.' }
        $entranceX = [double]$travel.xstart
        $State = & $island -Action Move -X $entranceX -Tolerance 12 -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 12)
        $sample = Read-SessionSnapshot
        $anchor = $sample.scene.submarineTravel
        $player = $sample.scene.player
        $inside = $anchor.can_be_used -and $player.can_use_tool -eq 1 -and
            $null -ne $player.x -and [Math]::Abs($entranceX - $player.x) -le 30
        Write-Verbose "Island approach to x=$entranceX from x=$($current.scene.player.x) reached x=$($State.scene.player.x); current x=$($player.x), tools $($player.can_use_tool), frame $($player.frame)."
        if ($inside) { break }
    }
    if (!$inside) { throw 'The diver did not stay inside the island submarine interaction range.' }
    foreach ($frames in 3, 1, 5) {
        $State = & $island -Action Interact -Frames $frames -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 5)
        $openedFrame = $State.frame
        try {
            return Wait-SessionSnapshot {
                param($sample)
                $sample.room -eq 'rm_main_island' -and $sample.scene.player.can_use_tool -eq 0 -and
                    !$sample.flags.transitioning -and $sample.frame -ge $openedFrame + 40
            } 'the native region dialog to open and settle' 1
        } catch {
            if ($_.Exception.Message -notlike 'Timed out waiting for the native region dialog*' -or $frames -eq 5) { throw }
            $State = Read-SessionSnapshot
            if ($State.room -ne 'rm_main_island' -or $State.flags.transitioning -or
                [Math]::Abs($State.scene.player.x - $entranceX) -gt 30) { throw }
            if ($State.scene.player.can_use_tool -eq 0) {
                return Wait-SessionSnapshot {
                    param($sample)
                    $sample.room -eq 'rm_main_island' -and $sample.scene.player.can_use_tool -eq 0 -and
                        !$sample.flags.transitioning -and $sample.frame -ge $openedFrame + 40
                } 'the native region dialog to settle' 2
            }
            if ($State.scene.player.can_use_tool -ne 1 -or !$State.scene.submarineTravel.can_be_used) { throw }
        }
    }
}

function Enter-SessionRegion($State, $Destination) {
    Set-SessionPhase 'selecting-region'
    $slotX = 0.374 + $Destination.column * 50.0 / 640
    $expanded = $State.numbers.total_skill_levels_upgraded -ge 95
    $slotY = if ($expanded) { (88 + $Destination.row * 58.0) / 360 } else { 0.488 }
    $confirmY = if ($expanded) { 320.0 / 360 } else { 0.645 }
    $State = Invoke-RegionClick $State $slotX $slotY
    return Invoke-RegionClick $State 0.278 $confirmY -ConfirmsDive -ExpectedRoom $Destination.room
}

function Save-NativeChestPayout($State, [double]$ExpectedShells) {
    $null = Get-StageSeconds 15 18
    Write-Verbose 'The stock chest paid after its save timer. Confirming the purse on a shallow return trip.'
    $State = Open-SessionRegionDialog $State
    $State = Enter-SessionRegion $State $regions[100]
    $departure = @{save=$null}
    $null = Wait-SessionSnapshot {
        param($sample)
        $saved = Read-NativeSave
        if ($sample.room -eq $regions[100].room -and $saved.sha256 -and $saved.shellCoins -eq $ExpectedShells) {
            $departure.save = $saved
            return $true
        }
        return $false
    } 'the native departure to save the completed chest payout' 4
    $returnArgs = @{
        Action='Return'; Mailbox=$Mailbox; SavePath=$SavePath; BeforeDiveSaveHash=$departure.save.sha256
        RequireLiveDiver=$true
        TimeoutSeconds=(Get-StageSeconds 8 18)
    }
    $State = & $dive @returnArgs
    $final = Wait-ExpectedNativeSave $State -Condition {
        param($sample, $saved)
        $saved.shellCoins -eq $ExpectedShells -and $saved.storeShellCoins -eq 0 -and $saved.storeQueuedJellyfish -eq 0
    }
    if (!$final.save) { throw 'The native return did not verify the completed chest payout.' }
    ++$script:payoutSaveRuns
    return $final.state
}

function Wait-RecoverableInputTimeout($State, [long]$LastInputFrame) {
    $deadline = [Math]::Min($timer.Elapsed.TotalSeconds + 1.0, $sessionDeadline - 8)
    while ($timer.Elapsed.TotalSeconds -lt $deadline) {
        $player = $State.scene.player
        if ($State.pid -ne $gamePid -or $State.room -ne $region.room -or !$State.inputReady -or
            $State.flags.transitioning -or $State.flags.pause -or $State.flags.player_inventory_open -or
            $State.flags.in_cutscene -or $player.can_use_tool -ne 1 -or $player.oxygen -le 0) { return }

        $anchor = $State.scene.submarineLeave
        if ($State.writtenUtc -and $State.activeInputFrames -eq 0 -and !$State.guiPointer.active -and
            $player.frame -gt $LastInputFrame -and $State.frame -ge $player.frame -and
            $State.frame - $player.frame -le 30 -and $null -ne $player.x -and $null -ne $player.y -and
            $null -ne $anchor.frame -and $anchor.frame -le $State.frame -and $State.frame - $anchor.frame -le 45 -and
            $null -ne $anchor.x -and $null -ne $anchor.y) {
            $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$State.writtenUtc).TotalSeconds
            if ($age -ge -0.5 -and $age -le 1.0) { return $State }
        }

        Start-Sleep -Milliseconds 25
        $State = Read-SessionSnapshot
    }
}

function Get-NativeWalletDelta($Before, $After) {
    if (!$Before -or !$After) { return $null }
    $delta = @{}
    foreach ($currency in $walletFields.Keys) {
        $delta[$currency] = [double]$After.wallet[$currency] - [double]$Before.wallet[$currency]
    }
    return $delta
}

function Get-EmptyResourceStreak($Before, $After, [int]$Previous) {
    $delta = Get-NativeWalletDelta $Before $After
    if (!$delta) { return $Previous }
    if ($delta.obsidian -gt 0 -or $delta.mushrooms -gt 0 -or $delta.crystals -gt 0 -or $delta.scrap -gt 0) { return 0 }
    return ($Previous + 1)
}

function Get-DeferredResourceBacklog($State, $Save, $Before) {
    if ($State.pid -ne $gamePid -or $State.room -ne 'rm_main_island' -or
        $State.flags.files_loaded -ne $true -or $State.flags.submarine_storage_available -ne $true -or
        $State.flags.transitioning -or $State.flags.pause -or $State.flags.in_cutscene -or
        $State.flags.is_on_final_cutscene -or $State.flags.player_inventory_open -or
        $State.activeInputFrames -ne 0 -or $State.guiPointer.active -or $State.scene.player.can_use_tool -ne 1 -or
        !$Before.sha256 -or !$Save.sha256 -or !$Save.catchPipeline -or
        $Save.storageAutoOutput -ne $true -or $Save.transmutatorAutoOutput -ne $true -or
        $Save.transmutatorOutputType -ne 2 -or $null -eq $Save.storeShellCoins -or $Save.storeShellCoins -lt 0) {
        return
    }

    foreach ($resource in 'scrap','crystals','mushrooms','obsidian') {
        if ($null -eq $Save.wallet[$resource] -or $null -eq $Before.wallet[$resource] -or
            $Save.wallet[$resource] -lt $Before.wallet[$resource]) { return }
    }
    $inventories = $Save.catchPipeline.inventories
    if ($null -eq $Save.playerJellyfish -or $Save.playerJellyfish -ne $inventories.player_inventory.count -or
        $null -eq $Save.submarineJellyfish -or $Save.submarineJellyfish -ne $inventories.submarine_inventory.count -or
        $null -eq $Save.transmutatorInputJellyfish -or $Save.transmutatorInputJellyfish -ne $inventories.transmutator_inventory_in.count -or
        $null -eq $Save.transmutatorOutputJellyfish -or $Save.transmutatorOutputJellyfish -ne $inventories.transmutator_inventory_out.count -or
        $null -eq $Save.storeQueuedJellyfish -or $Save.storeQueuedJellyfish -ne $inventories.store_inventory.count) {
        return
    }
    return [pscustomobject]@{
        saveSha256=$Save.sha256; pid=$State.pid; frame=$State.frame
        playerJellyfish=$Save.playerJellyfish; submarineJellyfish=$Save.submarineJellyfish
        transmutatorInputJellyfish=$Save.transmutatorInputJellyfish; transmutatorOutputJellyfish=$Save.transmutatorOutputJellyfish
        storeQueuedJellyfish=$Save.storeQueuedJellyfish; storeShellCoins=$Save.storeShellCoins
        totalJellyfish=$Save.catchPipeline.count; playerRequiresTransfer=$Save.playerJellyfish -gt 0
    }
}

function Get-BackpackSpaceStop($State, $Save, $DivePerformance) {
    if ($State.pid -ne $gamePid -or $State.room -ne 'rm_main_island' -or $State.flags.files_loaded -ne $true -or
        $State.flags.transitioning -or $State.flags.pause -or $State.flags.in_cutscene -or
        $State.flags.is_on_final_cutscene -or $State.flags.player_inventory_open -or
        $State.activeInputFrames -ne 0 -or $State.guiPointer.active -or $State.scene.player.can_use_tool -ne 1 -or
        !$Save.sha256 -or $null -eq $Save.playerRedJellyfishCompatibleSpace -or
        $Save.playerRedJellyfishCompatibleSpace -lt 0 -or $Save.playerJellyfishSlotCapacity -le 0) { return }
    $space = $Save.playerRedJellyfishCompatibleSpace
    $capacity = $Save.playerJellyfishSlotCapacity
    $priorFull = $DivePerformance.reason -in 'dynamic-native-pack-full','native-pack-full' -or
        ($DivePerformance.packFull.source -and $DivePerformance.packFull.fullFrame -gt 0)
    if ($space -gt 0 -and (!$priorFull -or $space -ge $capacity)) { return }
    return [pscustomobject]@{
        pid=$State.pid; frame=$State.frame; saveSha256=$Save.sha256; speciesId=11; rarity=0
        compatibleSpace=$space; slotCapacity=$capacity; priorFull=[bool]$priorFull
        reason=if ($space -eq 0) { 'no-compatible-slot' } else { 'native-full-less-than-one-stack' }
    }
}

function Invoke-SessionRun($State) {
    $baseline = Read-NativeSave
    if (!$baseline) { throw "Could not read the original Shelldiver save at '$SavePath'." }
    if ($Depth -eq 1200 -and $FillBackpack -and !$baseline.submarineBubbleOwned) {
        throw 'Filling the backpack at 1200m requires the original Submarine Recover I skill.'
    }
    $resumeDive = $State.room -in $diveRooms
    if ($resumeDive -and $State.room -ne $region.room) {
        throw "The resident diver is in '$($State.room)'. Use the matching depth to resume this expedition."
    }
    if (!$resumeDive) {
        $initial = Start-ResidentGame $State
        $State = Wait-SessionSnapshot {
            param($sample)
            $sample.frame -gt $initial.frame -and $sample.activeInputFrames -eq 0 -and
                !$sample.flags.transitioning -and $null -ne $sample.scene.player.x
        } 'a live, idle island'
    }
    $receipts = @()
    $completedSave = $null
    $retrySaveHash = $null
    $emptyResourceStreak = 0
    $stoppedForLowYield = $false
    $backpackSpaceStop = $null
    $checkBackpackBetweenRounds = $Depth -eq 1200 -and $Kind -eq 'Resource' -and $BatchSettlement -and $ReturnBetweenRounds
    if ($Kind -in 'Resource','Mixed' -and $PlasmaHoldFrames -lt 100 -and
        ($Depth -notin 500,900,1000,1200 -or $Kind -ne 'Resource' -or $PlasmaHoldFrames -lt $baseline.magmaPlasmaChargeFrames+11)) {
        throw 'A short plasma pulse requires a supported resource expedition and at least the saved native charge plus eleven steps.'
    }
    $magmaIResource = $Depth -eq 1000 -and $Kind -eq 'Resource'
    $verifyBacklogOnReturn = $Depth -eq 1200 -and $Kind -eq 'Resource' -and $BatchSettlement -and $DeferShopPayout -and
        !$ReturnImmediately -and $baseline.storageAutoOutput -and $baseline.transmutatorAutoOutput -and
        $baseline.transmutatorOutputType -eq 2 -and $baseline.catchPipeline
    $deferredBacklog = $null
    $canRetry = $BatchSettlement -and !$ReturnBetweenRounds -and
        $Depth -in 300,400,500,600,700,800,900,1000 -and $State.flags.submarine_storage_available

    for ($round = 1; $round -le $Rounds; ++$round) {
        $roundStartedUtc = [DateTime]::UtcNow
        $roundStartedMs = $timer.ElapsedMilliseconds
        $roundSaveBefore = if ($completedSave) { $completedSave } else { $baseline }
        $previousEmptyStreak = $emptyResourceStreak
        $null = Get-StageSeconds 12 90
        $diveArguments = @{
            Action='Dive'; Kind=$Kind; Mailbox=$Mailbox; SavePath=$SavePath;
            ConfirmX=$ReturnConfirmX; ConfirmY=$ReturnConfirmY; HarvestSeconds=$HarvestSeconds; ReturnOxygen=$ReturnOxygen
            PlasmaHoldFrames=$PlasmaHoldFrames; UseSubmarineBubble=$baseline.submarineBubbleOwned
        }
        if ($FillBackpack) { $diveArguments.FillBackpack = $true }
        if ($Depth -eq 1200 -and $Kind -eq 'Jellyfish') {
            $diveArguments.UseSubmarineAmmoBubble = $baseline.submarineAmmoBubbleOwned
            $diveArguments.MagmaBubblePenetration = $baseline.magmaBubblePenetration
            $diveArguments.MagmaBubbleProjectileSpeed = $baseline.magmaBubbleProjectileSpeed
            $diveArguments.MagmaBubbleProjectileLifetime = $baseline.magmaBubbleProjectileLifetime
        }
        if ($Depth -in 1000,1100,1200 -and $baseline.magmaShockResistance) { $diveArguments.MagmaShockResistance = $true }
        if (($magmaIResource -or $Depth -eq 1200) -and $baseline.magmaShockResistanceII) {
            $diveArguments.MagmaShockResistanceII = $true
        }
        if (($magmaIResource -or $Depth -in 1100,1200) -and $baseline.magmaShockFrequency) {
            $diveArguments.MagmaShockFrequency = $true
        }
        if ($magmaIResource -or ($Depth -eq 1200 -and $Kind -eq 'Resource')) { $diveArguments.UseSubmarineAmmoBubble = $baseline.submarineAmmoBubbleOwned }
        if ($Depth -in 500,900,1000,1100,1200 -and $Kind -eq 'Resource') {
            $diveArguments.MagmaPlasmaAimRange = $baseline.magmaPlasmaAimRange
            $diveArguments.MagmaPlasmaChargeFrames = $baseline.magmaPlasmaChargeFrames
            if ($Depth -eq 1000) { $diveArguments.MagmaMineSector = $MagmaMineSector }
        }
        if ($ReturnImmediately) {
            $diveArguments.Action = 'Return'
            $diveArguments.Remove('Kind')
            $diveArguments.RequireLiveDiver = $true
        }
        if ($retrySaveHash) {
            $diveArguments.BeforeDiveSaveHash = $retrySaveHash
            $retrySaveHash = $null
        }
        if ($State.room -ne $region.room) {
            if ($State.numbers.total_skill_levels_upgraded -lt $region.requiredRanks) {
                throw "The native save has not unlocked $Depth meters."
            }
            if (!$StartAtDialog -or $round -gt 1) { $State = Open-SessionRegionDialog $State }
            $beforeDive = Read-NativeSave
            if (!$beforeDive -or $beforeDive.shellCoins -ne $State.numbers.shell_coins -or
                $beforeDive.scrapCoins -ne $State.numbers.scrap_coins) {
                throw 'The island balance has not reached the original game save yet.'
            }
            $State = Enter-SessionRegion $State $region
            if (($magmaIResource -or $Depth -in 1100,1200) -and $State.autoplayBeforeEntryFrame) {
                $diveArguments.MagmaBeforeEntryFrame = $State.autoplayBeforeEntryFrame
            }
            $enteredSave = Read-NativeSave
            if (!$enteredSave) { throw 'The original native save was unavailable after entering the ocean.' }
            $diveArguments.BeforeDiveSaveHash = $enteredSave.sha256
        }

        Set-SessionPhase 'diving'
        $diveArguments.TimeoutSeconds = Get-StageSeconds 8 ([Math]::Max(24,$HarvestSeconds + 19))
        $holdForOperator = $HoldResult -and $round -eq $Rounds
        $holdForRetry = $canRetry -and $round -lt $Rounds
        if ($holdForOperator -or $holdForRetry) { $diveArguments.HoldResult = $true }
        $nativeLoss = $false
        $storageDue = $false
        $recoveredInputFrame = $null
        $failedInputFrame = $null
        $diveStartedMs = $timer.ElapsedMilliseconds
        $launchMs = $diveStartedMs - $roundStartedMs
        try {
            $State = & $dive @diveArguments
        } catch {
            if ($_.Exception.GetBaseException() -is [OperationCanceledException]) { throw }
            $failure = $_.Exception.Message
            $observed = Read-SessionSnapshot
            $safeReturn = $null
            if ($failure -cmatch "^Timed out waiting for fresh telemetry after 'input' frame ([0-9]{1,18})\.$") {
                $failedInputFrame = [long]$Matches[1]
                $safeReturn = Wait-RecoverableInputTimeout $observed $failedInputFrame
            }
            $magmaRetreatFailed = $Depth -in 1000,1100,1200 -and $failure -in @(
                'No safe Magma retreat step was available after twelve fresh samples.',
                'No safe Magma II return step was available after six native observations.',
                'The native submarine confirmation did not open.',
                'The inactive diver is outside the native submarine confirmation range.',
                'The native submarine confirmation did not open after the guarded interaction pulses.',
                'The native inventory remained open before returning.',
                'The dynamic Magma diver did not regain control before docking.',
                'No safe dynamic Magma return step was available.',
                'Timed out waiting for the original submarine air to refill the tank.'
            )
            if ($magmaRetreatFailed -and $observed.room -eq $region.room -and $observed.pid -eq $gamePid -and
                $observed.scene.player.oxygen -gt 0 -and $observed.scene.player.can_use_tool -eq 1 -and
                $observed.activeInputFrames -eq 0 -and !$observed.flags.transitioning) {
                $safeReturn = $observed
            }
            if ($safeReturn) {
                $returnArgs = @{
                    Action='Return'; Mailbox=$Mailbox; SavePath=$SavePath; HoldResult=$holdForOperator
                    ConfirmX=$ReturnConfirmX; ConfirmY=$ReturnConfirmY; TimeoutSeconds=(Get-StageSeconds 8 18)
                }
                if ($diveArguments.BeforeDiveSaveHash) {
                    $returnArgs.BeforeDiveSaveHash = $diveArguments.BeforeDiveSaveHash
                }
                if ($Depth -in 1000,1100,1200) {
                    $returnArgs.RecoverMagma = $true
                    $returnArgs.MagmaShockResistance = $baseline.magmaShockResistance
                    if ($magmaIResource) { $returnArgs.Kind = 'Resource' }
                    if ($magmaIResource -or $Depth -eq 1200) {
                        $returnArgs.MagmaShockFrequency = $baseline.magmaShockFrequency
                        $returnArgs.MagmaShockResistanceII = $baseline.magmaShockResistanceII
                        $returnArgs.UseSubmarineBubble = $baseline.submarineBubbleOwned
                        $returnArgs.UseSubmarineAmmoBubble = $baseline.submarineAmmoBubbleOwned
                    }
                    $returnArgs.MagmaMineSector = $MagmaMineSector
                }
                $recoveryMessage = if ($magmaRetreatFailed) {
                    'Retrying from fresh native telemetry because the return corridor was temporarily blocked.'
                } else { "Native input ended at frame $failedInputFrame. Returning the live diver." }
                Set-SessionPhase 'recovering-return' $recoveryMessage
                try {
                    $State = & $dive @returnArgs
                } catch {
                    if ($_.Exception.Message -ne 'No safe dynamic Magma return step was available.') { throw }
                    $outcome = Read-SessionSnapshot
                    if ($outcome.pid -ne $gamePid -or $outcome.room -ne $region.room -or
                        $null -eq $outcome.scene.player.oxygen -or $outcome.scene.player.oxygen -gt 0 -or
                        $outcome.scene.player.can_use_tool -ne 0) { throw }
                    $State = Finish-NativeResult $outcome -VerifiedLoss
                    $nativeLoss = $true
                }
                $recoveredInputFrame = $failedInputFrame
            } else {
                if ($observed.room -ne $region.room -or $null -eq $observed.scene.player.oxygen -or
                    $observed.scene.player.oxygen -gt 0 -or $observed.scene.player.can_use_tool -ne 0) { throw }
                $State = Finish-NativeResult $observed -VerifiedLoss
                $nativeLoss = $true
            }
        }
        $diveFinishedMs = $timer.ElapsedMilliseconds
        $diveMs = $diveFinishedMs - $diveStartedMs
        $divePerformance = $State.autoplayDive
        $script:latestDivePerformance = $divePerformance
        if (($holdForOperator -or $holdForRetry) -and $State.room -eq $region.room -and $State.pid -eq $gamePid) {
            $savedResult = Read-NativeSave
            if (!$savedResult -or $State.scene.player.can_use_tool -ne 0 -or $State.activeInputFrames -ne 0) {
                throw 'The native expedition result is not settled.'
            }
            if ($holdForOperator) {
                return [pscustomobject]@{
                    phase='result'; room=$State.room; pid=$gamePid; depth=$Depth; frame=$State.frame
                    oxygen=$State.scene.player.oxygen; elapsedMs=$timer.ElapsedMilliseconds
                    roundsCompleted=$receipts.Count; heldResultRound=$round; nativeSave=$savedResult
                    recoveredInputFrame=$recoveredInputFrame; divePerformance=$divePerformance
                    roundElapsedMs=$timer.ElapsedMilliseconds - $roundStartedMs
                    launchMs=$launchMs; diveMs=$diveMs
                    nativeWalletDelta=Get-NativeWalletDelta $roundSaveBefore $savedResult
                }
            }
            if ($StopAfterEmptyResourceRounds -gt 0) {
                $emptyResourceStreak = Get-EmptyResourceStreak $roundSaveBefore $savedResult $previousEmptyStreak
                $stoppedForLowYield = $emptyResourceStreak -ge $StopAfterEmptyResourceRounds -and $round -lt $Rounds
            }
            $canStoreCatch = $savedResult.playerJellyfish -eq 0 -or
                ($savedResult.playerJellyfish + $savedResult.submarineJellyfish -le $savedResult.submarineJellyfishCapacity)
            $storageDue = !$canStoreCatch
            if (!$stoppedForLowYield -and $State.flags.is_tutorial_finished -and $State.flags.submarine_storage_available -and $canStoreCatch -and
                $State.scene.player.oxygen -gt 0) {
                $resultFrame = $State.frame
                $retryTimer = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $retry = Invoke-NativeRetry $State $savedResult
                } catch {
                    if ($_.Exception.Message -notlike 'Timed out waiting for the native Retry*') { throw }
                    $State = Read-SessionSnapshot
                    if ($State.room -ne $region.room -or $State.scene.player.can_use_tool -ne 0) { throw }
                    $retry = $null
                }
                if ($retry) {
                    $State = $retry.state
                    $completedSave = $retry.save
                    $retrySaveHash = $completedSave.sha256
                    $receipts += [pscustomobject]@{
                        round=$round; depth=$Depth; startedUtc=$roundStartedUtc.ToString('o')
                        finishedUtc=[DateTime]::UtcNow.ToString('o'); returnedFrame=$resultFrame
                        nativeRetry=$true; nativeRetryElapsedMs=$retryTimer.ElapsedMilliseconds
                        roundElapsedMs=$timer.ElapsedMilliseconds - $roundStartedMs
                        launchMs=$launchMs; diveMs=$diveMs
                        postDiveMs=$timer.ElapsedMilliseconds - $diveFinishedMs
                        settlementMs=0
                        nativeWalletDelta=Get-NativeWalletDelta $roundSaveBefore $completedSave
                        divePerformance=$divePerformance
                        nativeOxygenLoss=$false; settlementPerformed=$false; nativeBalanceVerified=$true
                        shellsAfterReturn=$completedSave.shellCoins; shellsAfterSale=$completedSave.shellCoins
                        scrapAfterReturn=$completedSave.scrapCoins; jellyfishInNativeSave=$completedSave.playerJellyfish
                        shopShellsAfterReturn=$savedResult.storeShellCoins; shopQueuedAfterReturn=$savedResult.storeQueuedJellyfish
                        jellyfishInSubmarine=$completedSave.submarineJellyfish
                    }
                    continue
                }
            }
            $State = Finish-NativeResult $State -VerifiedCheckpoint
        }
        if ($State.room -ne 'rm_main_island' -or $State.pid -ne $gamePid) {
            throw 'The native dive did not return to the same island session.'
        }
        $returned = $State
        $returnFrame = $returned.frame
        $State = Wait-SessionSnapshot {
            param($sample)
            $player = $sample.scene.player
            $sample.room -eq 'rm_main_island' -and !$sample.flags.transitioning -and
                $sample.frame -ge $returnFrame + 85 -and $player.frame -gt $returnFrame -and
                $sample.frame - $player.frame -le 30 -and $player.can_use_tool -eq 1 -and
                $sample.scene.submarineTravel.can_be_used
        } 'the island player to finish the expedition return transition' 5
        $verifyBacklogThisRound = $verifyBacklogOnReturn -and !$nativeLoss
        $deferredBacklog = $null
        $settlementDue = !$verifyBacklogThisRound -and
            (!$BatchSettlement -or $storageDue -or $stoppedForLowYield -or $round -eq $Rounds -or (Test-NativePackFull))
        $postDiveIdleMs = $timer.ElapsedMilliseconds - $diveFinishedMs
        $settlementStartMs = $timer.ElapsedMilliseconds
        if ($settlementDue) { $State = Invoke-SessionSettlement $State -QueueSalesOnly:$DeferShopPayout }
        $catchRouting = if ($settlementDue) { $State.automaticCatchRouting }
        $settlementMs = $timer.ElapsedMilliseconds - $settlementStartMs
        $saveVerifyStartMs = $timer.ElapsedMilliseconds
        Set-SessionPhase 'verifying-save'
        if ($verifyBacklogThisRound) {
            $verification = Wait-ExpectedNativeSave $State -AllowConcurrentShopPricing -Condition {
                param($sample, $saved)
                [bool](Get-DeferredResourceBacklog $sample $saved $roundSaveBefore)
            }
            if ($verification.save) {
                $deferredBacklog = Get-DeferredResourceBacklog $verification.state $verification.save $roundSaveBefore
            }
        } else {
            $verification = Wait-ExpectedNativeSave $State
        }
        $State = $verification.state
        $completedSave = $verification.save
        if ($checkBackpackBetweenRounds -and $round -lt $Rounds -and !$nativeLoss -and $completedSave) {
            # Check the original save again immediately before allowing another departure.
            $latest = Read-NativeSave
            $candidate = Get-BackpackSpaceStop $State $latest $divePerformance
            if ($candidate -and $latest.sha256 -ne $completedSave.sha256) {
                $fresh = Wait-ExpectedNativeSave $State -Seconds 3 -AllowConcurrentShopPricing -Condition {
                    param($sample, $saved)
                    [bool](Get-BackpackSpaceStop $sample $saved $divePerformance)
                }
                $candidate = $null
                if ($fresh.save) {
                    $State = $fresh.state
                    $completedSave = $fresh.save
                    $candidate = Get-BackpackSpaceStop $State $completedSave $divePerformance
                    if ($verifyBacklogThisRound) {
                        $deferredBacklog = Get-DeferredResourceBacklog $State $completedSave $roundSaveBefore
                        if (!$deferredBacklog) { throw 'The newer backpack save did not verify the native Resource return.' }
                    }
                }
            }
            $backpackSpaceStop = $candidate
        }
        if ($StopAfterEmptyResourceRounds -gt 0 -and $completedSave) {
            $emptyResourceStreak = Get-EmptyResourceStreak $roundSaveBefore $completedSave $previousEmptyStreak
            $stoppedForLowYield = !$backpackSpaceStop -and $emptyResourceStreak -ge $StopAfterEmptyResourceRounds -and $round -lt $Rounds
            if ($stoppedForLowYield -and !$settlementDue -and !$verifyBacklogThisRound) {
                $settlementDue = $true
                $settlementStartMs = $timer.ElapsedMilliseconds
                $State = Invoke-SessionSettlement $State -QueueSalesOnly:$DeferShopPayout
                $catchRouting = $State.automaticCatchRouting
                $settlementMs += $timer.ElapsedMilliseconds - $settlementStartMs
                $saveVerifyStartMs = $timer.ElapsedMilliseconds
                Set-SessionPhase 'verifying-save'
                $verification = Wait-ExpectedNativeSave $State
                $State = $verification.state
                $completedSave = $verification.save
            }
        }
        $receipts += [pscustomobject]@{
            round = $round
            startedUtc = $roundStartedUtc.ToString('o')
            finishedUtc = [DateTime]::UtcNow.ToString('o')
            depth = $Depth
            roundElapsedMs = $timer.ElapsedMilliseconds - $roundStartedMs
            launchMs = $launchMs
            diveMs = $diveMs
            islandReadyMs = $postDiveIdleMs
            settlementMs = $settlementMs
            automaticCatchRouting = $catchRouting
            automatedCatchBacklogDeferred = [bool]($deferredBacklog -and $deferredBacklog.totalJellyfish -gt 0)
            automatedCatchBacklog = $deferredBacklog
            saveVerifyMs = $timer.ElapsedMilliseconds - $saveVerifyStartMs
            nativeWalletDelta = Get-NativeWalletDelta $roundSaveBefore $completedSave
            nativeOxygenLoss = $nativeLoss
            recoveredInputFrame = $recoveredInputFrame
            divePerformance = $divePerformance
            nativeRetry = $false
            returnedFrame = $returned.frame
            shellsAfterReturn = $returned.numbers.shell_coins
            shellsAfterSale = $State.numbers.shell_coins
            scrapAfterReturn = $returned.numbers.scrap_coins
            shopShellsAfterReturn = $returned.numbers.store_shell_coins
            settlementPerformed = $settlementDue
            stoppedForBackpackSpace = [bool]$backpackSpaceStop
            backpackSpaceStop = $backpackSpaceStop
            jellyfishInNativeSave = $completedSave.playerJellyfish
            jellyfishInSubmarine = $completedSave.submarineJellyfish
            nativeBalanceVerified = ($null -ne $completedSave)
        }
        if (!$completedSave -or $stoppedForLowYield -or $backpackSpaceStop) { break }
    }
    $progress = $completedSave -and $completedSave.sha256 -ne $baseline.sha256 -and
        (($walletFields.Keys | Where-Object { $completedSave.wallet[$_] -gt $baseline.wallet[$_] }) -or
         ($null -ne $completedSave.playerJellyfish -and $null -ne $baseline.playerJellyfish -and
          $completedSave.playerJellyfish -gt $baseline.playerJellyfish))

    return [pscustomobject]@{
        room = $State.room
        pid = $gamePid
        hostPid = $PID
        startedUtc = $startedUtc.ToString('o')
        finishedUtc = [DateTime]::UtcNow.ToString('o')
        elapsedMs = $timer.ElapsedMilliseconds
        roundsCompleted = $receipts.Count
        nativeRetries = @($receipts | Where-Object nativeRetry).Count
        emptyResourceStreak = $emptyResourceStreak
        stoppedForLowYield = $stoppedForLowYield
        stoppedForBackpackSpace = [bool]$backpackSpaceStop
        backpackSpaceStop = $backpackSpaceStop
        payoutSaveRuns = $payoutSaveRuns
        shopPayoutDeferred = $DeferShopPayout.IsPresent
        automatedCatchBacklogDeferred = [bool]($deferredBacklog -and $deferredBacklog.totalJellyfish -gt 0)
        automatedCatchBacklog = $deferredBacklog
        rounds = $receipts
        kind = $Kind
        nativeBalanceVerified = ($null -ne $completedSave)
        nativeSaveProgressVerified = [bool]$progress
        saveBefore = $baseline
        verifiedSaveAfter = $completedSave
        latestSave = Read-NativeSave
    }
}
function Get-SessionStatus {
    $snapshot = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds 3
    $save = Read-NativeSave
    return [pscustomobject]@{
        session = Read-SessionFile $sessionPath
        stop = Read-SessionFile $stopPath
        pid = $snapshot.pid
        room = $snapshot.room
        frame = $snapshot.frame
        writtenUtc = $snapshot.writtenUtc
        inputReady = $snapshot.inputReady
        inputError = $snapshot.inputError
        activeInputFrames = $snapshot.activeInputFrames
        virtualPointerActive = $snapshot.guiPointer.active
        oxygen = $snapshot.scene.player.oxygen
        oxygenMax = $snapshot.scene.player.oxygen_max
        canUseTool = $snapshot.scene.player.can_use_tool
        shellCoins = $snapshot.numbers.shell_coins
        scrapCoins = $snapshot.numbers.scrap_coins
        storeShellCoins = $snapshot.numbers.store_shell_coins
        playerInventory = $snapshot.inventories.player
        projectiles = $snapshot.projectiles
        nativeSave = $save
        playerJellyfishSlotCapacity = $save.playerJellyfishSlotCapacity
        playerJellyfishSpaceByType = $save.playerJellyfishSpaceByType
        playerRedJellyfishCompatibleSpace = $save.playerRedJellyfishCompatibleSpace
        supportsBackpackSpaceStop = $true
        supportsCollectShopCredit = $true
        supportsDeferredResourceBacklog = $true
    }
}

function Start-ResidentGame($State) {
    if ($State.room -eq 'rm_main_island') { return $State }
    if ($State.room -eq 'rm_logo') {
        $State = Wait-SessionSnapshot { param($sample) $sample.room -eq 'rm_main_menu' } 'the main menu in the resident game' 8
    }
    if ($State.room -ne 'rm_main_menu') { throw 'Native launch requires a resident game at its title or main menu.' }

    Set-SessionPhase 'launching'
    if ($State.menuButtons -notcontains 'continue_button' -and $State.menuButtons -notcontains 'Continue') {
        $null = & $control -Action title-enter -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 3)
        $State = Wait-SessionSnapshot {
            param($sample)
            $sample.room -eq 'rm_main_menu' -and ($sample.menuButtons -contains 'continue_button' -or $sample.menuButtons -contains 'Continue')
        } 'the native Continue button' 8
    }
    if (!$State.flags.files_loaded -or !$State.flags.is_tutorial_finished -or $State.flags.transitioning) {
        throw 'The resident Continue action is not ready on the existing save.'
    }
    $null = & $control -Action continue -ParametersJson '{"selectionVerified":true}' -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 5)
    return Wait-SessionSnapshot {
        param($sample)
        $sample.room -eq 'rm_main_island' -and !$sample.flags.transitioning -and $null -ne $sample.scene.player.x
    } 'the native Continue action to reach the island' 8
}

function Assert-ReadyNativeResult($State) {
    if ($State.room -notin $diveRooms -or $State.flags.transitioning -or
        $State.activeInputFrames -ne 0 -or $State.guiPointer.active -or !$State.guiPointer.buttonHooks -or
        $State.scene.player.can_use_tool -ne 0) {
        throw 'The resident game is outside the expected settled expedition result state.'
    }
}

function Finish-NativeResult($State, [switch]$VerifiedLoss, [switch]$VerifiedCheckpoint) {
    if (!$ResultVerified -and !$VerifiedLoss -and !$VerifiedCheckpoint) {
        throw 'Confirm the native Expedition End result through CLI evidence before using -ResultVerified.'
    }
    if ($VerifiedLoss -and ($null -eq $State.scene.player.oxygen -or $State.scene.player.oxygen -gt 0)) {
        throw 'An automatic expedition loss requires an observed depleted oxygen gauge.'
    }
    Assert-ReadyNativeResult $State
    $baseline = Read-NativeSave
    if (!$baseline) { throw 'The completed native expedition does not have a save receipt.' }
    Set-SessionPhase 'finishing-result'
    $expected = 'the native result to return to the island'
    $arrived = {
        param($sample)
        $sample.frame -gt $ack.frame -and $sample.room -eq 'rm_main_island' -and !$sample.flags.transitioning
    }
    for ($attempt = 0; $attempt -lt 2; ++$attempt) {
        $hover = & $control -Action aim -ParametersJson '{"x":0.354,"y":0.732,"holdFrames":30}' `
            -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 3)
        if ($null -eq $hover.frame) { throw 'The native Finish hover did not report its acknowledgement frame.' }
        $ready = Wait-SessionSnapshot {
            param($sample)
            $sample.frame -gt $hover.frame + 6 -and $sample.activeInputFrames -eq 0
        } 'the Finish button to receive a native hover' 2
        if ($ready.room -ne $State.room -or $ready.flags.transitioning -or $ready.scene.player.can_use_tool -ne 0) {
            throw 'The native result changed while hovering over Finish.'
        }
        $ack = & $control -Action click -ParametersJson '{"x":0.354,"y":0.732,"button":1,"holdFrames":2}' `
            -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 3)
        if ($null -eq $ack.frame) { throw 'The native result click did not report its acknowledgement frame.' }
        try {
            return Wait-SessionSnapshot $arrived $expected 3
        } catch {
            if ($attempt -ne 0 -or $_.Exception.Message -ne "Timed out waiting for $expected.") { throw }
            $fresh = Read-SessionSnapshot
            if ($fresh.flags.transitioning -or $fresh.room -eq 'rm_main_island') {
                return Wait-SessionSnapshot $arrived $expected 4
            }
            Assert-ReadyNativeResult $fresh
            if ($fresh.room -ne $State.room -or $fresh.frame -le $ack.frame -or
                $fresh.scene.player.oxygen -ne $State.scene.player.oxygen -or
                (Read-NativeSave).sha256 -ne $baseline.sha256) {
                throw 'The native result changed after Finish and cannot be retried safely.'
            }
        }
    }
}
function Invoke-NativeRetry($State, $SavedResult) {
    Assert-ReadyNativeResult $State
    if ($State.room -ne $region.room -or !$State.flags.is_tutorial_finished -or $State.scene.player.oxygen -le 0) {
        throw 'The selected depth does not have an unlocked, successful native expedition result.'
    }
    if ($Depth -notin 300, 400, 500, 600, 700, 800, 900, 1000) { throw 'Retry button coordinates are not verified at this depth.' }

    Set-SessionPhase 'retrying-expedition'
    $expected = 'the native Retry to replenish oxygen in the same expedition room'
    $arrived = {
        param($sample)
        $player = $sample.scene.player
        $sample.room -eq $region.room -and !$sample.flags.transitioning -and
            $sample.frame -gt $ack.frame + 35 -and $player.frame -gt $ack.frame -and
            $player.can_use_tool -eq 1 -and $player.oxygen -ge .90 * $player.oxygen_max -and
            $sample.scene.submarineLeave.frame -gt $ack.frame
    }
    for ($attempt = 0; $attempt -lt 2; ++$attempt) {
        $ack = & $control -Action click -ParametersJson '{"x":0.479,"y":0.732,"button":1,"holdFrames":1}' `
            -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 3)
        if ($null -eq $ack.frame) { throw 'The native Retry click did not report its acknowledgement frame.' }
        try {
            $next = Wait-SessionSnapshot $arrived $expected 3
            break
        } catch {
            if ($attempt -ne 0 -or $_.Exception.Message -ne "Timed out waiting for $expected.") { throw }
            $fresh = Read-SessionSnapshot
            if ($fresh.flags.transitioning -or $fresh.scene.player.can_use_tool -eq 1) {
                $next = Wait-SessionSnapshot $arrived $expected 4
                break
            }
            Assert-ReadyNativeResult $fresh
            if ($fresh.room -ne $State.room -or $fresh.frame -le $ack.frame + 35 -or
                $fresh.scene.player.oxygen -ne $State.scene.player.oxygen -or
                (Read-NativeSave).sha256 -ne $SavedResult.sha256) { throw 'Native result changed after the Retry click.' }
            $hover = & $control -Action aim -ParametersJson '{"x":0.479,"y":0.732,"holdFrames":30}' `
                -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 1 3)
            if ($null -eq $hover.frame) { throw 'The native Retry hover did not report its acknowledgement frame.' }
            $fresh = Wait-SessionSnapshot {
                param($sample)
                $sample.frame -gt $hover.frame + 30 -and !$sample.guiPointer.active
            } 'the native Retry hover to finish' 2
            Assert-ReadyNativeResult $fresh
            if ($fresh.room -ne $State.room -or $fresh.scene.player.oxygen -ne $State.scene.player.oxygen -or
                (Read-NativeSave).sha256 -ne $SavedResult.sha256) { throw 'Native result changed after the Retry click.' }
        }
    }

    $resumedSave = Read-NativeSave
    if (!$resumedSave -or ($walletFields.Keys | Where-Object { $resumedSave.wallet[$_] -ne $SavedResult.wallet[$_] }) -or
        $resumedSave.playerJellyfish + $resumedSave.submarineJellyfish -ne
            $SavedResult.playerJellyfish + $SavedResult.submarineJellyfish) {
        throw 'The original save did not confirm the same wallet and catch after native Retry.'
    }
    [IO.File]::Delete((Join-Path $Mailbox 'dive-return.json'))
    return [pscustomobject]@{state=$next; save=$resumedSave}
}

function Wait-NativeAutomatedCatch($State, $Before, [switch]$FinishProduction) {
    if (!$Before.catchPipeline) { throw 'The native automatic catch pipeline needs all five original saved inventories.' }
    $deadline = $timer.Elapsed.TotalSeconds + (Get-StageSeconds 2 150)
    $lastAdvance = $timer.Elapsed.TotalSeconds
    $last = $Before
    $lastFrame = [long]$State.frame
    $unreconciledAt = $null
    $observations = 0
    do {
        $sample = Read-SessionSnapshot
        if ($sample.room -ne 'rm_main_island' -or $sample.pid -ne $gamePid) {
            throw 'The resident island changed during automatic catch routing.'
        }
        if ($sample.frame -gt $lastFrame -and $sample.activeInputFrames -eq 0 -and
            !$sample.flags.transitioning -and !$sample.flags.pause -and !$sample.flags.player_inventory_open -and
            !$sample.flags.in_cutscene -and !$sample.guiPointer.active -and $sample.scene.player.can_use_tool -eq 1) {
            $lastFrame = $sample.frame
            $saved = Read-NativeSave
            if ($saved -and $saved.sha256 -ne $last.sha256) {
                $comparison = Compare-NativeCatchPipeline $last $saved
                if ($comparison) {
                    $unreconciledAt = $null
                    if ($comparison.creditedShells -gt 0 -or @($comparison.stageDeltas.Values | Where-Object { $_ -ne 0 }).Count) {
                        $lastAdvance = $timer.Elapsed.TotalSeconds
                        ++$observations
                    }
                    $last = $saved
                } elseif ($null -eq $unreconciledAt) {
                    # The stock save can be observed between two native outputs; wait for a reconcilable save.
                    $unreconciledAt = $timer.Elapsed.TotalSeconds
                } elseif ($timer.Elapsed.TotalSeconds-$unreconciledAt -ge 3) {
                    throw 'The original automatic catch pipeline has an unexplained inventory or wallet change.'
                }
            }
            if ($saved -and $null -eq $unreconciledAt -and $saved.sha256 -eq $last.sha256 -and
                $saved.submarineTransmutable -eq 0 -and (!$FinishProduction -or
                    ($saved.transmutatorInputJellyfish -eq 0 -and $saved.transmutatorOutputJellyfish -eq 0 -and
                     $saved.storeQueuedJellyfish -eq 0 -and ($null -eq $sample.inventories.store.total -or $sample.inventories.store.total -eq 0)))) {
                $receipt = Compare-NativeCatchPipeline $Before $saved
                if (!$receipt) { throw 'Could not reconcile the original automatic catch routing.' }
                $receipt.observations = $observations
                $receipt.throughFrame = $sample.frame
                $receipt.finishedProduction = [bool]$FinishProduction
                return @{state=$sample;save=$saved;receipt=$receipt}
            }
        }
        if ($timer.Elapsed.TotalSeconds-$lastAdvance -ge 22) { break }
        Start-Sleep -Milliseconds 55
    } while ($timer.Elapsed.TotalSeconds -lt $deadline)
    throw 'The resident game did not verify stock automatic catch routing before its progress budget expired.'
}

function Withdraw-SubmarineCatch($State, $Save) {
    if (!$State.flags.submarine_storage_available -or $Save.playerJellyfishCapacity -le 0) {
        throw 'The native submarine withdrawal or backpack capacity is unavailable.'
    }
    $State = & $island -Action Move -X 3616 -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 12)
    if ($Save.storageAutoOutput) {
        $Save = Read-NativeSave
        if (!$Save -or !$Save.catchPipeline -or $Save.submarineTransmutable -gt 0) {
            throw 'Eligible submarine fish must finish stock routing before a manual withdrawal.'
        }
    }
    while ($Save.submarineJellyfish -gt 0 -and $Save.playerJellyfish -lt $Save.playerJellyfishCapacity) {
        $total = $Save.submarineJellyfish + $Save.playerJellyfish
        $storageBefore = $Save.submarineJellyfish
        $frames = if ($storageBefore -ge 8) { 180 } else { 90 }
        $State = & $island -Action Interact -Frames $frames -HoldOnly -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 8)
        $verified = Wait-ExpectedNativeSave $State -Seconds 3 -Condition {
            param($sample, $saved)
            $saved.submarineJellyfish -lt $storageBefore -and
                $saved.submarineJellyfish + $saved.playerJellyfish -eq $total
        }
        if (!$verified.save) {
            $latest = Read-NativeSave
            if (!$latest -or $latest.playerJellyfish -le 0 -or
                $latest.playerJellyfish + $latest.submarineJellyfish -ne $total) {
                throw 'Native submarine withdrawal did not confirm the saved inventory transfer.'
            }
            # A free count does not guarantee a free slot for the remaining species.
            return [pscustomobject]@{state=$verified.state; save=$latest}
        }
        $State = $verified.state
        $Save = $verified.save
    }
    return [pscustomobject]@{state=$State; save=$Save}
}

function Wait-NativeShopSave($State, [int]$Seconds, [scriptblock]$Condition, [switch]$WatchShopPricing) {
    $deadline = $timer.Elapsed.TotalSeconds + (Get-StageSeconds 1 $Seconds)
    $latest = $null
    $pricing = if ($WatchShopPricing) { @{lastActivity=$timer.Elapsed.TotalSeconds} }
    do {
        $sample = Read-SessionSnapshot
        if ($sample.room -ne 'rm_main_island' -or $sample.pid -ne $gamePid) {
            throw 'The resident island changed during native shop transfer.'
        }
        if ($sample.frame -gt $State.frame -and $sample.activeInputFrames -eq 0 -and
            !$sample.flags.transitioning -and !$sample.flags.pause -and !$sample.flags.player_inventory_open -and
            !$sample.flags.in_cutscene -and !$sample.guiPointer.active -and
            $sample.scene.player.can_use_tool -eq 1 -and $sample.scene.player.frame -gt $State.frame -and
            $sample.frame - $sample.scene.player.frame -le 30 -and
            $null -ne $sample.scene.player.x -and $null -ne $sample.scene.shop.x -and
            [Math]::Abs($sample.scene.player.x - $sample.scene.shop.x) -le 20) {
            $saved = Read-NativeSave
            if ($saved -and $null -ne $saved.playerJellyfish -and $null -ne $saved.storeCompatibleJellyfishSpace) {
                $liveCount = $sample.inventories.player.total
                if ($null -eq $liveCount -or $liveCount -eq $saved.playerJellyfish) {
                    $latest = $saved
                    if (& $Condition $saved) { return @{ state=$sample; save=$saved; accepted=$true } }
                }
            }
        }
        if ($pricing -and !(Test-NativeShopPricingProgress $pricing $sample $latest)) { break }
        Start-Sleep -Milliseconds 45
    } while ($timer.Elapsed.TotalSeconds -lt $deadline)
    return @{ state=$sample; save=$latest; accepted=$false }
}

function ConvertTo-NativeShellAmount($Value) {
    if ($Value -isnot [double]) { return [decimal]$Value }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    # A direct double-to-decimal cast drops significant digits. F0 retains the exact integral Real.
    $format = if ($Value -eq [Math]::Truncate($Value)) { 'F0' } else { 'R' }
    return [decimal]::Parse($Value.ToString($format, $culture), [Globalization.NumberStyles]::Float, $culture)
}

function Measure-NativeShellTransfer($BeforeWallet, $BeforeShop, $AfterWallet, $AfterShop, [int]$HeldSteps) {
    foreach ($value in $BeforeWallet, $BeforeShop, $AfterWallet, $AfterShop) {
        if ($null -eq $value -or ![double]::IsFinite([double]$value) -or $value -lt 0) { return }
    }

    $paid = (ConvertTo-NativeShellAmount $AfterWallet) - (ConvertTo-NativeShellAmount $BeforeWallet)
    $shopDelta = (ConvertTo-NativeShellAmount $AfterShop) - (ConvertTo-NativeShellAmount $BeforeShop)
    $walletPeak = [Math]::Max([double]$BeforeWallet, [double]$AfterWallet)
    $shopPeak = [Math]::Max([double]$BeforeShop, [double]$AfterShop)
    # The original chest issues at most one coin per held Step. Each coin has one debit and one wallet add.
    $walletUlp = [Math]::BitIncrement($walletPeak) - $walletPeak
    $shopUlp = [Math]::BitIncrement($shopPeak) - $shopPeak
    $roundingBound = [decimal](($walletUlp + $shopUlp) * $HeldSteps / 2)
    return @{
        paidShells=$paid; balanceDelta=$paid + $shopDelta; roundingBound=$roundingBound
        remainingShopShells=$AfterShop
    }
}

function Test-NativeShopCredit($Save) {
    return $Save.sha256 -and $null -ne $Save.shellCoins -and $null -ne $Save.storeShellCoins -and
        $null -ne $Save.storeQueuedJellyfish -and [double]::IsFinite([double]$Save.shellCoins) -and
        [double]::IsFinite([double]$Save.storeShellCoins) -and $Save.shellCoins -ge 0 -and
        $Save.storeShellCoins -ge 0 -and $Save.storeQueuedJellyfish -ge 0
}

function Measure-NativeShopCollection($Before, $After) {
    if (!(Test-NativeShopCredit $After) -or $After.sha256 -eq $Before.sha256 -or
        $After.shellCoins -le $Before.shellCoins -or
        ($walletFields.Keys | Where-Object { $_ -ne 'shells' -and $Before.wallet[$_] -ne $After.wallet[$_] })) {
        return
    }
    $balance = Measure-NativeShellTransfer $Before.shellCoins $Before.storeShellCoins $After.shellCoins $After.storeShellCoins $shopChestHoldSteps
    if (!$balance -or $balance.paidShells -le 0 -or $balance.balanceDelta -lt -$balance.roundingBound) { return }
    $earned = if ($balance.balanceDelta -gt $balance.roundingBound) { $balance.balanceDelta } else { 0 }
    return @{
        paidShells=$balance.paidShells; earnedShellsWhileCollecting=$earned
        balanceDelta=$balance.balanceDelta; roundingBound=$balance.roundingBound
    }
}

function Invoke-NativeShopCollection($State) {
    if ($State.room -ne 'rm_main_island' -or $State.flags.files_loaded -ne $true -or
        $State.flags.transitioning -or $State.flags.pause -or $State.flags.in_cutscene -or
        $State.flags.is_on_final_cutscene -or $State.flags.player_inventory_open -or
        $State.activeInputFrames -ne 0 -or $State.guiPointer.active -or
        $State.scene.player.can_use_tool -ne 1) {
        throw 'Collecting credited shop shells requires a ready and idle resident island.'
    }
    Set-SessionPhase 'collecting-shop-credit'
    $save = Read-NativeSave
    if (!(Test-NativeShopCredit $save) -or $null -eq $State.numbers.shell_coins -or
        $null -eq $State.numbers.store_shell_coins) {
        throw 'Could not read the native wallet and credited shop balance.'
    }

    $receipt = [pscustomobject]@{
        phase='no-earnings'; paidShells=0; earnedShellsWhileCollecting=$null; balanceDelta=$null; roundingBound=$null
        issuedPulse=$false; before=$save; after=$null
        queuedJellyfish=$save.storeQueuedJellyfish; remainingShopShells=$save.storeShellCoins
    }
    if ($save.shellCoins -ne $State.numbers.shell_coins -or
        ($save.storeShellCoins -gt 0) -ne ($State.numbers.store_shell_coins -gt 0)) {
        # A previous pulse or a fresh sale may be visible before the original save catches up.
        $receipt.phase = 'waiting-native-save'
    } elseif ($save.storeShellCoins -gt 0) {
        if ($null -eq $State.scene.chest.x -or $null -eq $State.scene.chest.y) {
            throw 'The native island chest position is unavailable.'
        }
        $chestX = [double]$State.scene.chest.x
        $chestY = [double]$State.scene.chest.y
        $State = & $island -Action Move -X $chestX -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 12)
        $baseline = Wait-ExpectedNativeSave $State -Seconds 3 -AllowConcurrentShopPricing -Condition {
            param($sample, $saved)
            (Test-NativeShopCredit $saved) -and $sample.flags.files_loaded -eq $true -and
                !$sample.flags.transitioning -and !$sample.flags.pause -and !$sample.flags.in_cutscene -and
                !$sample.flags.is_on_final_cutscene -and !$sample.flags.player_inventory_open -and
                $sample.activeInputFrames -eq 0 -and !$sample.guiPointer.active -and
                $sample.scene.player.can_use_tool -eq 1 -and $sample.scene.player.frame -gt $State.frame -and
                $sample.frame - $sample.scene.player.frame -le 30 -and $null -ne $sample.scene.player.x -and
                $null -ne $sample.scene.player.y -and [Math]::Abs($sample.scene.player.x - $chestX) -le 15 -and
                [Math]::Abs($sample.scene.player.y - $chestY) -le 24
        }
        $State = $baseline.state
        if (!$baseline.save) {
            if ($null -eq $State.scene.player.x -or $null -eq $State.scene.player.y -or
                [Math]::Abs($State.scene.player.x - $chestX) -gt 15 -or
                [Math]::Abs($State.scene.player.y - $chestY) -gt 24) {
                throw 'The player did not reach the verified native chest range.'
            }
            $receipt.phase = 'waiting-native-save'
        } else {
            $receipt.before = $baseline.save
            $receipt.remainingShopShells = $baseline.save.storeShellCoins
            $receipt.queuedJellyfish = $baseline.save.storeQueuedJellyfish
            if ($baseline.save.storeShellCoins -gt 0 -and $State.numbers.store_shell_coins -gt 0) {
                $before = $baseline.save
                $receipt.issuedPulse = $true
                $State = & $island -Action Interact -Frames $shopChestHoldSteps -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 8)
                $verification = Wait-ExpectedNativeSave $State -Seconds 4 -AllowConcurrentShopPricing -Condition {
                    param($sample, $saved)
                    [bool](Measure-NativeShopCollection $before $saved)
                }
                $State = $verification.state
                if ($verification.save) {
                    $measurement = Measure-NativeShopCollection $before $verification.save
                    $receipt.phase = 'paid'
                    $receipt.paidShells = $measurement.paidShells
                    $receipt.earnedShellsWhileCollecting = $measurement.earnedShellsWhileCollecting
                    $receipt.balanceDelta = $measurement.balanceDelta
                    $receipt.roundingBound = $measurement.roundingBound
                    $receipt.after = $verification.save
                    $receipt.remainingShopShells = $verification.save.storeShellCoins
                    $receipt.queuedJellyfish = $verification.save.storeQueuedJellyfish
                } else {
                    $persisted = Read-NativeSave
                    if ($persisted -and $persisted.shellCoins -gt $before.shellCoins -and
                        !(Measure-NativeShopCollection $before $persisted)) {
                        throw 'The saved wallet and shop balance did not verify the original chest collection.'
                    }
                    if ($null -eq $State.numbers.shell_coins -or $State.numbers.shell_coins -le $before.shellCoins) {
                        throw 'The native chest interaction did not increase the live wallet.'
                    }
                    $receipt.phase = 'waiting-native-save'
                }
            } elseif (($baseline.save.storeShellCoins -gt 0) -ne ($State.numbers.store_shell_coins -gt 0)) {
                $receipt.phase = 'waiting-native-save'
            }
        }
    }
    $State | Add-Member -NotePropertyName shopCollection -NotePropertyValue $receipt -Force
    return $State
}

function Invoke-SessionSettlement($State, [switch]$QueueSalesOnly) {
    if ($State.room -ne 'rm_main_island') { throw 'Settlement requires the resident game to be on the island.' }
    Set-SessionPhase 'settling'
    $save = Read-NativeSave
    if (!$save -or $null -eq $save.playerJellyfish) { throw 'Could not read the native backpack before selling.' }
    $flowReceipts = [Collections.Generic.List[object]]::new()
    if ($save.storageAutoOutput -and $save.transmutatorOutputType -gt 0 -and $save.submarineTransmutable -gt 0) {
        $routed = Wait-NativeAutomatedCatch $State $save
        $State = $routed.state
        $save = $routed.save
        $flowReceipts.Add($routed.receipt)
    }
    $carried = $save.playerJellyfish
    while ($carried -gt 0 -or $save.submarineJellyfish -gt 0) {
        if ($save.submarineJellyfish -gt 0 -and $carried -lt $save.playerJellyfishCapacity) {
            $withdrawn = Withdraw-SubmarineCatch $State $save
            $State = $withdrawn.state
            $save = $withdrawn.save
            $carried = $save.playerJellyfish
        }
        if ($carried -le 0 -and $save.submarineJellyfish -eq 0) { break }
        if ($carried -le 0) { throw 'The native submarine catch could not be moved into the backpack.' }
        if ($null -eq $State.scene.shop.x) { throw 'The native island shop position is unavailable.' }
        $State = & $island -Action Move -X $State.scene.shop.x -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 12)
        while ($carried -gt 0) {
            $ready = Wait-NativeShopSave $State 2 {
                param($saved)
                $saved.playerJellyfish -le $carried -and $saved.submarineJellyfish -eq $save.submarineJellyfish
            }
            if (!$ready.accepted) { throw 'Could not confirm the native backpack at the shop before selling.' }
            $State = $ready.state
            $save = $ready.save
            $carried = $save.playerJellyfish
            if ($carried -le 0) { break }
            if ($save.storeCompatibleJellyfishSpace -le 0) {
                $roomReady = Wait-NativeShopSave $State (Get-StageSeconds 1 150) -WatchShopPricing -Condition {
                    param($saved)
                    $saved.playerJellyfish -le $carried -and $saved.submarineJellyfish -eq $save.submarineJellyfish -and
                        ($saved.playerJellyfish -eq 0 -or $saved.storeCompatibleJellyfishSpace -gt 0)
                }
                if (!$roomReady.accepted) { throw 'The native shop did not make compatible space for the remaining catches.' }
                $State = $roomReady.state
                $save = $roomReady.save
                $carried = $save.playerJellyfish
                if ($carried -le 0) { break }
            }

            for ($attempt = 1; $attempt -le 2; ++$attempt) {
                $before = $save
                $State = & $island -Action Interact -Frames 90 -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 8)
                $receipt = Wait-NativeShopSave $State 3 {
                    param($saved)
                    $saved.sha256 -ne $before.sha256 -and $saved.playerJellyfish -lt $before.playerJellyfish -and
                        $saved.submarineJellyfish -eq $before.submarineJellyfish
                }
                $State = $receipt.state
                $save = $receipt.save
                if ($receipt.accepted) { break }
                if ($attempt -eq 2 -or !$save -or $save.sha256 -eq $before.sha256 -or
                    $save.playerJellyfish -ne $before.playerJellyfish -or $save.submarineJellyfish -ne $before.submarineJellyfish -or
                    $save.storeCompatibleJellyfishSpace -le $before.storeCompatibleJellyfishSpace) {
                    throw 'The native shop did not save a reduction in the carried catch.'
                }
                $retry = Wait-NativeShopSave $State 1 {
                    param($saved)
                    $saved.playerJellyfish -eq $before.playerJellyfish -and
                        $saved.submarineJellyfish -eq $before.submarineJellyfish -and
                        $saved.storeCompatibleJellyfishSpace -gt $before.storeCompatibleJellyfishSpace
                }
                if (!$retry.accepted) { throw 'The native shop did not confirm safe room for a second deposit.' }
                $State = $retry.state
                $save = $retry.save
            }
            $carried = $save.playerJellyfish
        }
    }

    if ($QueueSalesOnly) {
        if ($flowReceipts.Count) { $State | Add-Member -NotePropertyName automaticCatchRouting -NotePropertyValue $flowReceipts.ToArray() -Force }
        return $State
    }
    if ($save.storageAutoOutput -and $save.transmutatorAutoOutput -and $save.transmutatorOutputType -gt 0 -and
        ($save.transmutatorInputJellyfish -gt 0 -or $save.transmutatorOutputJellyfish -gt 0 -or $save.storeQueuedJellyfish -gt 0)) {
        $priced = Wait-NativeAutomatedCatch $State $save -FinishProduction
        $State = $priced.state
        $save = $priced.save
        $flowReceipts.Add($priced.receipt)
    }
    if ($State.numbers.store_shell_coins -gt 0 -or $save.storeShellCoins -gt 0 -or $save.storeQueuedJellyfish -gt 0) {
        if ($null -eq $State.scene.chest.x) { throw 'The native island chest position is unavailable.' }
        $State = & $island -Action Move -X $State.scene.chest.x -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 12)
    }
    if ($save.storeQueuedJellyfish -gt 0) {
        $verification = Wait-ExpectedNativeSave $State -Seconds (Get-StageSeconds 1 150) -WatchShopPricing -Condition {
            param($sample, $saved)
            $saved.storeQueuedJellyfish -eq 0 -and
                ($null -eq $sample.inventories.store.total -or $sample.inventories.store.total -eq 0)
        }
        if (!$verification.save) { throw 'The native shop still has catches waiting to be priced.' }
        $State = $verification.state
        $save = $verification.save
    }

    $pending = $State.numbers.store_shell_coins
    $payouts = [Collections.Generic.List[object]]::new()
    while ($pending -gt 0) {
        $beforePulse = $State
        $State = & $island -Action Interact -Frames $shopChestHoldSteps -Mailbox $Mailbox -TimeoutSeconds (Get-StageSeconds 3 8)
        $verification = Wait-ExpectedNativeSave $State -Condition {
            param($sample, $saved)
            $balance = Measure-NativeShellTransfer $beforePulse.numbers.shell_coins $pending $sample.numbers.shell_coins $sample.numbers.store_shell_coins $shopChestHoldSteps
            $balance -and $balance.paidShells -gt 0 -and $balance.remainingShopShells -lt $pending -and
                [Math]::Abs($balance.balanceDelta) -le $balance.roundingBound -and $saved.storeQueuedJellyfish -eq 0
        }
        $observed = $verification.state
        $remaining = $observed.numbers.store_shell_coins
        $balance = Measure-NativeShellTransfer $beforePulse.numbers.shell_coins $pending $observed.numbers.shell_coins $remaining $shopChestHoldSteps
        if (!$verification.save) {
            $saved = Read-NativeSave
            if (!$balance -or $balance.paidShells -le 0 -or $remaining -ge $pending -or
                [Math]::Abs($balance.balanceDelta) -gt $balance.roundingBound -or
                !$saved -or $saved.shellCoins -gt $observed.numbers.shell_coins -or
                $saved.storeShellCoins -ne $remaining -or $saved.storeQueuedJellyfish -ne 0 -or
                $saved.playerJellyfish -ne 0 -or $saved.submarineJellyfish -ne 0 -or
                ($walletFields.Keys | Where-Object {
                    $_ -ne 'shells' -and [double]$observed.numbers.($walletFields[$_]) -ne $saved.wallet[$_]
                })) {
                throw 'The native chest did not save a complete payout for this interaction.'
            }
            if ($remaining -eq 0) {
                $State = Save-NativeChestPayout $observed $observed.numbers.shell_coins
            } else {
                # The next original chest pulse can save both payouts after the earlier coins land.
                $State = $observed
            }
        } else {
            $State = $observed
        }
        $payouts.Add([pscustomobject]$balance)
        $pending = $State.numbers.store_shell_coins
    }
    if ($payouts.Count -or $save.storeShellCoins -gt 0) {
        $saved = Read-NativeSave
        if (!$saved -or $saved.shellCoins -ne $State.numbers.shell_coins -or
            $null -eq $saved.storeShellCoins -or $saved.storeShellCoins -ne 0 -or
            $null -eq $State.numbers.store_shell_coins -or $State.numbers.store_shell_coins -ne 0 -or
            $null -eq $saved.storeQueuedJellyfish -or $saved.storeQueuedJellyfish -ne 0) {
            throw 'The original save did not confirm the entire shop payout with zero remaining.'
        }
        $State | Add-Member -NotePropertyName nativeShopSettlement -NotePropertyValue ([pscustomobject]@{
            verified=$true; pulses=$payouts.ToArray(); remainingShopShells=$saved.storeShellCoins
            queuedJellyfish=$saved.storeQueuedJellyfish; walletShells=$saved.shellCoins; saveSha256=$saved.sha256
        }) -Force
    }
    if ($flowReceipts.Count) { $State | Add-Member -NotePropertyName automaticCatchRouting -NotePropertyValue $flowReceipts.ToArray() -Force }
    return $State
}

function Test-NativePackFull {
    $save = Read-NativeSave
    if (!$save) { throw 'Could not verify the native pack before deferring settlement.' }
    return $save.playerJellyfish -gt 0 -and
        ($null -eq $save.playerJellyfishCapacity -or $save.playerJellyfish -ge $save.playerJellyfishCapacity)
}

if ($Action -eq 'Status') { return Get-SessionStatus }
if ($Action -eq 'Stop') {
    $requestedTicks = [DateTime]::UtcNow.Ticks
    Write-SessionFile $stopPath @{requestedTicks = $requestedTicks; requestedUtc = [DateTime]::UtcNow.ToString('o')}
    try {
        $ack = & $control -Action stop -Mailbox $Mailbox -TimeoutSeconds 8
    } catch {
        throw "The host batch stop was requested, but the resident game did not acknowledge native stop. $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        hostStopRequested = $true
        nativeStopAcknowledged = $ack.ok
        stopFrame = $ack.frame
        hostPid = $ack.hostPid
        requestedUtc = ([DateTime]::new($requestedTicks, [DateTimeKind]::Utc)).ToString('o')
        nativeStopQueuedUtc = $ack.hostQueuedUtc
        nativeStopAcknowledgedUtc = $ack.hostAcknowledgedUtc
        status = Get-SessionStatus
    }
}

if ($hasReturnConfirmX -ne $hasReturnConfirmY) {
    throw 'Pass both -ReturnConfirmX and -ReturnConfirmY when overriding the native button center.'
}
if ($Action -in 'FinishResult','RetryResult' -and !$ResultVerified) {
    throw 'Confirm the native Expedition End result through CLI evidence before using -ResultVerified.'
}

$null = [IO.Directory]::CreateDirectory($Mailbox)
try {
    $lease = [IO.File]::Open((Join-Path $Mailbox 'session.lock'), 'OpenOrCreate', 'Write', 'None')
} catch [IO.IOException] {
    throw 'A Shelldiver session command already owns this mailbox.'
}
$previousStopPath = $env:SHELLDIVER_SESSION_STOP_PATH
$previousStartedTicks = $env:SHELLDIVER_SESSION_STARTED_TICKS
$env:SHELLDIVER_SESSION_STOP_PATH = $stopPath
$env:SHELLDIVER_SESSION_STARTED_TICKS = [string]$startedTicks

try {
    Set-SessionPhase 'starting'
    $state = Read-SessionSnapshot
    $gamePid = $state.pid
    if (!$gamePid) { throw 'The resident game snapshot is missing a process ID.' }
    $saveBeforeAction = Read-NativeSave
    switch ($Action) {
        'Launch' { $result = Start-ResidentGame $state }
        'FinishResult' {
            $result = Finish-NativeResult $state
            if ($SettleAfterResult) { $result = Invoke-SessionSettlement $result }
        }
        'RetryResult' { $result = (Invoke-NativeRetry $state $saveBeforeAction).state }
        'Settle' { $result = Invoke-SessionSettlement $state -QueueSalesOnly:$DeferShopPayout }
        'CollectShopCredit' { $result = Invoke-NativeShopCollection $state }
        'Run' { $result = Invoke-SessionRun $state }
    }
    $null = Get-StageSeconds 1 1
    Set-SessionPhase 'completed'
    if ($Action -ne 'Run') {
        $result | Add-Member -NotePropertyMembers @{
            commandHostPid = $PID
            commandStartedUtc = $startedUtc.ToString('o')
            commandFinishedUtc = [DateTime]::UtcNow.ToString('o')
            commandElapsedMs = $timer.ElapsedMilliseconds
            payoutSaveRuns = $payoutSaveRuns
            nativeSaveBefore = $saveBeforeAction
            nativeSaveAfter = Read-NativeSave
        }
    }
    return $result
} catch {
    if ($_.Exception.GetBaseException() -is [OperationCanceledException]) {
        Set-SessionPhase 'stopped' $_.Exception.Message
    } else {
        $originalError=$_.Exception.Message
        if ($FillBackpack -and $gamePid) {
            try {
                $live=& $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds 3
                if ($live.pid -eq $gamePid -and $live.room -in 'rm_ocean_magma_02','rm_ocean_magma_03' -and
                    $live.scene.player.oxygen -gt 0 -and !$live.flags.pause -and
                    !$live.flags.transitioning -and $live.activeInputFrames -eq 0) {
                    $null=& $control -Action input -Mailbox $Mailbox -TimeoutSeconds 3 -ParametersJson '{"frames":2,"values":{"pause":true}}'
                }
            } catch { Write-Verbose "Could not pause the original live diver after a control failure. $($_.Exception.Message)" }
        }
        Set-SessionPhase 'ended' $originalError
    }
    throw
} finally {
    $env:SHELLDIVER_SESSION_STOP_PATH = $previousStopPath
    $env:SHELLDIVER_SESSION_STARTED_TICKS = $previousStartedTicks
    $lease.Dispose()
}
