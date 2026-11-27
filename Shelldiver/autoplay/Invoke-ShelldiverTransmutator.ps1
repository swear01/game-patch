[CmdletBinding()]
param(
    [ValidateSet('Status', 'Transfer', 'TransferAll', 'TransferReady')] [string]$Action = 'Status',
    [ValidateRange(1, 600)] [int]$Frames = 45,
    [ValidateRange(4, 600)] [int]$TimeoutSeconds = 20,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json'),
    [string]$ControllerRoot = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/autoplay')
)

$ErrorActionPreference = 'Stop'
$control = Join-Path $ControllerRoot 'Invoke-Shelldiver.ps1'
$island = Join-Path $ControllerRoot 'Invoke-ShelldiverIsland.ps1'
$timer = [Diagnostics.Stopwatch]::StartNew()
$stationX = 3779.0
$stationY = 401.0
$gamePid = $null
$inventoryNames = [ordered]@{
    player = 'player_inventory'
    input = 'transmutator_inventory_in'
    output = 'transmutator_inventory_out'
    shop = 'store_inventory'
}

function Get-Budget([int]$Maximum) {
    $left = [int][Math]::Floor($TimeoutSeconds - $timer.Elapsed.TotalSeconds)
    if ($left -lt 1) { throw 'Timed out waiting for a verified native transmutator transfer.' }
    return [Math]::Min($Maximum, $left)
}

function Read-NativeStock {
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($SavePath, 'Open', 'Read', $share)
        try {
            $reader = [IO.StreamReader]::new($stream)
            try { $encoded = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        } finally {
            $stream.Dispose()
        }
        if (!$encoded.StartsWith('{')) {
            $binary = [Convert]::FromHexString($encoded)
            if ($binary.Length -le 16) { return }
            $length = [BitConverter]::ToInt32($binary, 12)
            if ($length -le 0 -or $length -gt ($binary.Length - 16)) { return }
            $encoded = [Text.Encoding]::UTF8.GetString($binary, 16, $length)
        }
        $stock = ConvertFrom-Json -InputObject $encoded
        if ($stock.global) { $stock = $stock.global }
        if (!$stock.skills_saved -or !$stock._all_inventories) { return }
        return $stock
    } catch [IO.IOException], [FormatException], [System.ArgumentException], [System.Management.Automation.RuntimeException] {
        return
    }
}

function Read-Inventories($Stock) {
    $counts = [ordered]@{}
    foreach ($name in $inventoryNames.Keys) {
        $inventory = $Stock._all_inventories.($inventoryNames[$name])
        if (!$inventory -or $null -eq $inventory.slots) {
            throw "Missing native inventory $($inventoryNames[$name])."
        }
        $counts[$name] = @{}
        foreach ($slot in $inventory.slots) {
            if ($slot.quantity -le 0) { continue }
            if ($null -eq $slot.id -or $slot.id -lt 0 -or $slot.type -notin 0, 1, 2, 3 -or
                [double]$slot.quantity -ne [long]$slot.quantity) {
                throw "Invalid occupied slot in $($inventoryNames[$name])."
            }
            $key = '{0},{1}' -f [long]$slot.id, [int]$slot.type
            $counts[$name][$key] += [long]$slot.quantity
        }
    }
    return $counts
}

function Get-StationInventorySpace($Inventory) {
    $capacity = [long]$Inventory.slot_capacity
    $slots = @($Inventory.slots)
    $slotCount = if ($null -ne $Inventory.slot_number) { [int]$Inventory.slot_number } else { $slots.Count }
    if ($capacity -le 0 -or $slotCount -le 0 -or $slots.Count -ne $slotCount) {
        throw 'The original station inventory does not prove its saved slots and stack capacity.'
    }
    $matchingSpace = @{}
    $emptySlots = 0
    $quantity = 0L
    $partialSlots = 0
    foreach ($slot in $slots) {
        $quantity += [long]$slot.quantity
        if ($slot.quantity -le 0) {
            ++$emptySlots
        } elseif ($slot.quantity -lt $capacity) {
            ++$partialSlots
            $key = '{0},{1}' -f [long]$slot.id,[int]$slot.type
            $matchingSpace[$key] += $capacity-[long]$slot.quantity
        }
    }
    return @{slotCapacity=$capacity;slotCount=$slotCount;capacity=$capacity*$slotCount;quantity=$quantity;
        emptySlots=$emptySlots;partialSlots=$partialSlots;matchingSpace=$matchingSpace}
}

function Get-StationInventoryFit($Destination, $Source, [int]$BelowRarity) {
    $eligible = 0L
    $compatible = 0L
    $emptyLoads = [Collections.Generic.List[long]]::new()
    foreach ($key in $Source.Keys) {
        if ([int]($key.Split(',')[1]) -ge $BelowRarity) { continue }
        $amount = [long]$Source[$key]
        $eligible += $amount
        $matched = [Math]::Min($amount,[long]$Destination.matchingSpace[$key])
        $compatible += $matched
        for ($remaining = $amount-$matched; $remaining -gt 0; $remaining -= $Destination.slotCapacity) {
            $emptyLoads.Add([Math]::Min($remaining,$Destination.slotCapacity))
        }
    }
    # An empty slot is shared, while a partial slot is reserved for its exact species and rarity.
    foreach ($load in ($emptyLoads | Sort-Object -Descending | Select-Object -First $Destination.emptySlots)) {
        $compatible += $load
    }
    return @{quantity=$eligible;compatibleQuantity=$compatible;canFitAll=$compatible -eq $eligible}
}

function Get-StationQueues($Stock, $Inventories, [int]$OutputType) {
    $input = Get-StationInventorySpace $Stock._all_inventories.transmutator_inventory_in
    $output = Get-StationInventorySpace $Stock._all_inventories.transmutator_inventory_out
    $shop = Get-StationInventorySpace $Stock._all_inventories.store_inventory
    return @{
        input=$input;output=$output;shop=$shop
        backpackFit=Get-StationInventoryFit $input $Inventories.player $OutputType
        shopFit=Get-StationInventoryFit $shop $Inventories.output 4
    }
}

function Get-StationPulseFrames([long]$Compatible, $LastPulse) {
    if (!$LastPulse -or $LastPulse.deposited -le 0) { return 120 }
    # Estimate the next hold from the last verified in-game transfer, then re-read the save.
    $estimate = [Math]::Ceiling($Compatible*$LastPulse.frames/[double]$LastPulse.deposited)+8
    return [int][Math]::Clamp($estimate,18.0,600.0)
}

function Read-Snapshot {
    $state = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds (Get-Budget 4)
    if (!$state.pid -or ($gamePid -and $state.pid -ne $gamePid)) {
        throw 'The resident Shelldiver process changed during the transmutator transfer.'
    }
    return $state
}

function Assert-Ready($State) {
    if ($State.room -ne 'rm_main_island' -or $State.inputReady -ne $true -or
        $State.flags.files_loaded -ne $true -or $State.flags.transitioning -or $State.flags.pause -or
        $State.flags.in_cutscene -or $State.flags.is_on_final_cutscene -or $State.flags.player_inventory_open -or
        $State.guiPointer.active -or $State.activeInputFrames -ne 0 -or
        $null -eq $State.scene.player.x -or $null -eq $State.scene.player.y) {
        throw 'The resident island is not ready for a native transmutator transfer.'
    }
    if ($State.inputError -and $State.inputError -ne 'Could not publish the game mailbox response.') {
        throw "Native input reported an error during transmutator transfer. $($State.inputError)"
    }
}

function Assert-NearStation($State) {
    if ([Math]::Abs([double]$State.scene.player.x - $stationX) -gt 8 -or
        [Math]::Abs([double]$State.scene.player.y - $stationY) -gt 35) {
        throw 'The player is outside the verified transmutator interaction range.'
    }
}

function Measure-Changes($Before, $After, [int]$OutputType) {
    $keys = @($Before.Keys | ForEach-Object { $Before[$_].Keys; $After[$_].Keys } | Sort-Object -Unique)
    $balances = @{}
    $changed = $false
    foreach ($key in $keys) {
        $species, $rarity = $key -split ','
        $type = [int]$rarity
        $delta = 0L
        foreach ($name in $Before.Keys) {
            $move = [long]$After[$name][$key] - [long]$Before[$name][$key]
            if ($name -eq 'player' -and $move -ne 0) { $changed = $true }
            $delta += $move
        }
        if (($type -eq $OutputType -and $delta -lt 0) -or
            ($type -lt $OutputType -and $delta -gt 0) -or
            ($type -gt $OutputType -and $delta -ne 0)) {
            throw "Unexpected native rarity change for species $species."
        }
        $balances[$species] += $delta
    }
    foreach ($species in $balances.Keys) {
        if ($balances[$species] -ne 0) { throw "Native inventory did not conserve species $species." }
    }
    return $changed
}

function Measure-AutomaticDeposit($Before, $After, [int]$OutputType) {
    $keys = @($Before.Keys; $After.Keys) | Sort-Object -Unique
    $deposited = 0L
    foreach ($key in $keys) {
        $type = [int](($key -split ',')[1])
        $delta = [long]$After[$key] - [long]$Before[$key]
        if ($delta -gt 0 -or ($delta -lt 0 -and $type -ge $OutputType)) {
            throw "Unexpected native backpack change for $key during automatic output."
        }
        $deposited -= $delta
    }
    return $deposited
}

$stock = Read-NativeStock
if (!$stock) { throw 'The original Game.json could not be read.' }
$unlocked = $stock.jellyfish_transmutator_available -eq $true -and
    [int]$stock.skills_saved.o_skill_jellyfish_transmutator -ge 1
$outputType = if ([int]$stock.skills_saved.o_skill_transmutator_golden -ge 1) { 2 } else { 1 }
$automaticOutput = [int]$stock.skills_saved.o_skill_transmutator_auto_output -ge 1
$crossAutomation = [ordered]@{
    sellOnTransmute = [int]$stock.skills_saved.o_skill_transmutator_sell -ge 1
    transmuteOnSale = [int]$stock.skills_saved.o_skill_store_transmutate -ge 1
}

if ($Action -eq 'Status') {
    $inventories = Read-Inventories $stock
    $queues = Get-StationQueues $stock $inventories $outputType
    return [pscustomobject]@{
        phase = 'status'
        unlocked = $unlocked
        outputType = $outputType
        automaticOutput = $automaticOutput
        unsupportedSkills = @()
        crossAutomation = $crossAutomation
        storeShellCoins = $stock.store_shell_coins
        position = @{ x = $stationX; y = $stationY }
        inventories = $inventories
        queues = $queues
        inputCanAcceptBackpack = $queues.backpackFit.compatibleQuantity -gt 0
    }
}
if (!$unlocked) { throw 'Game.json must show the purchased native transmutator and its activation.' }

if ($Action -in 'TransferAll','TransferReady' -and !$automaticOutput) {
    throw 'Batch deposits require the original automatic output upgrade.'
}

function Assert-StationMode($Stock) {
    if ($Stock.jellyfish_transmutator_available -ne $true -or
        [int]$Stock.skills_saved.o_skill_jellyfish_transmutator -lt 1 -or
        ([int]$Stock.skills_saved.o_skill_transmutator_golden -ge 1) -ne ($outputType -eq 2) -or
        ([int]$Stock.skills_saved.o_skill_transmutator_auto_output -ge 1) -ne $automaticOutput) {
        throw 'Native transmutator unlocks changed during the verified transfer.'
    }
}

function Read-StationSave {
    do {
        $stock = Read-NativeStock
        if ($stock) { Assert-StationMode $stock; return $stock }
        $null = Get-Budget 4
        Start-Sleep -Milliseconds 40
    } while ($true)
}

function Invoke-VerifiedStationPulse($Near, $Before, [int]$HoldFrames) {
    $checkpoint = & $island -Action Interact -HoldOnly -Frames $HoldFrames -Mailbox $Mailbox -TimeoutSeconds (Get-Budget 25)
    Assert-Ready $checkpoint
    Assert-NearStation $checkpoint
    do {
        $state = Read-Snapshot
        Assert-Ready $state
        Assert-NearStation $state
        $stock = Read-NativeStock
        if ($stock -and $state.frame -ge $checkpoint.frame -and $state.frame -gt $Near.frame) {
            Assert-StationMode $stock
            $after = Read-Inventories $stock
            $deposited = $null
            if ($automaticOutput) {
                # Native station and shop timers can advance in the same save. The typed backpack is the deposit proof.
                $deposited = Measure-AutomaticDeposit $Before.player $after.player $outputType
                $moved = $deposited -gt 0
            } else {
                $moved = Measure-Changes $Before $after $outputType
            }
            if ($moved) {
                return @{state=$state;after=$after;stock=$stock;deposited=$deposited;frames=$HoldFrames}
            }
        }
        Start-Sleep -Milliseconds 55
    } while ($true)
}

$Mailbox = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Mailbox)
if (!(Test-Path -LiteralPath $Mailbox -PathType Container)) { throw 'A resident Shelldiver mailbox is required.' }
try {
    $lease = [IO.File]::Open((Join-Path $Mailbox 'session.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch [IO.IOException] {
    throw 'A Shelldiver session command already owns this mailbox.'
}
try {
    $near = Read-Snapshot
    $gamePid = $near.pid
    Assert-Ready $near
    $stock = Read-StationSave
    $first = Read-Inventories $stock
    $current = $first
    $queues = Get-StationQueues $stock $first $outputType
    $total = 0L
    $pulses = 0
    $lastPulse = $null
    $stopReason = $null
    if ($Action -eq 'Transfer') {
        if ($automaticOutput -and $queues.backpackFit.compatibleQuantity -le 0) {
            throw 'The native transmutator has no eligible backpack catch with a compatible input slot.'
        }
        if (!$automaticOutput -and $first.shop.Count -ne 0) {
            throw 'Settle the stock shop before measuring a transmutator transfer.'
        }
        if (!$automaticOutput -and !$queues.backpackFit.quantity -and !$first.output.Count) {
            throw 'There are no eligible backpack fish or finished station output to transfer.'
        }
    }

    $initialQueue = $queues
    $firstRoom = $queues.backpackFit.compatibleQuantity
    $positionVerified = [Math]::Abs([double]$near.scene.player.x-$stationX) -le 8 -and
        [Math]::Abs([double]$near.scene.player.y-$stationY) -le 35
    while ($true) {
        if ($Action -ne 'Transfer' -and !$queues.backpackFit.quantity) { $stopReason='backpack-cleared'; break }
        if ($Action -eq 'TransferReady' -and $pulses -gt 0) {
            if ($total -ge $firstRoom) { $stopReason='verified-space-filled'; break }
            if ($TimeoutSeconds-$timer.Elapsed.TotalSeconds -lt 4) { $stopReason='verified-pulse-budget'; break }
        }
        if ($automaticOutput -and !$queues.backpackFit.compatibleQuantity) {
            if ($Action -eq 'TransferReady') { $stopReason='input-full'; break }
            if ($Action -eq 'Transfer') { throw 'The native transmutator has no eligible backpack catch with a compatible input slot.' }
            $null = Get-Budget 4
            Start-Sleep -Milliseconds 125
            $stock = Read-StationSave
            $current = Read-Inventories $stock
            $queues = Get-StationQueues $stock $current $outputType
            continue
        }
        if (!$positionVerified) {
            $null = & $island -Action Move -X $stationX -Tolerance 6 -Mailbox $Mailbox -TimeoutSeconds (Get-Budget 25)
            $near = Read-Snapshot
            Assert-Ready $near
            Assert-NearStation $near
            $positionVerified = $true
            $stock = Read-StationSave
            $current = Read-Inventories $stock
            $queues = Get-StationQueues $stock $current $outputType
            continue
        }

        $hold = if ($Action -eq 'Transfer') { $Frames } else { Get-StationPulseFrames $queues.backpackFit.compatibleQuantity $lastPulse }
        $lastPulse = Invoke-VerifiedStationPulse $near $current $hold
        ++$pulses
        $total += $lastPulse.deposited
        $near = $lastPulse.state
        $current = $lastPulse.after
        $queues = Get-StationQueues $lastPulse.stock $current $outputType
        if ($Action -eq 'Transfer') { $stopReason='pulse-verified'; break }
    }
    $verified = if ($automaticOutput) { Measure-AutomaticDeposit $first.player $current.player $outputType }
    if ($automaticOutput -and $verified -ne $total) {
        throw 'The final typed backpack does not verify the measured station transfers.'
    }
    return [pscustomobject]@{
        phase='transferred';pid=$gamePid;frame=$near.frame;outputType=$outputType;automaticOutput=$automaticOutput
        crossAutomation=$crossAutomation;deposited=$verified;before=$first;after=$current
        initialQueue=$initialQueue;finalQueue=$queues;remainingEligible=$queues.backpackFit.quantity
        stopReason=$stopReason;pulses=$pulses;elapsedMs=$timer.ElapsedMilliseconds
    }
} finally {
    $lease.Dispose()
}
