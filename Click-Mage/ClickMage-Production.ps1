# Dot-source this file to use inventory and production commands.
. (Join-Path $PSScriptRoot 'ClickMage-Logistics.ps1')

function Get-CmAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        $Map,
        [switch]$IncludePending
    )

    if (!$Map) { $Map = Get-CmMap }
    $count = @($Map.resources | Where-Object {
        $_.type -eq $Type -and ($_.collectible -or $IncludePending)
    }).Count
    foreach ($chest in $Map.buildings.chests | Where-Object type -eq $Type) {
        $count += $chest.count
    }
    $count
}

function Ensure-CmMaterial {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][ValidateRange(1, 2000)][int]$Count,
        [int]$ProcessorId,
        [switch]$AssignUnused,
        [switch]$StowOutput,
        [ValidateRange(1, 500)][int]$MaxRounds = 160,
        [ValidateRange(1, 240)][int]$WaitForNaturalSeconds = 30,
        $SandStagingPoint
    )

    $before = Get-CmAvailable -Type $Type
    $scale = Invoke-CmControl -Action status
    if ($scale.paused -or $scale.timeScale -le 0) { throw 'Resume the game before starting production.' }
    $stow = if ($PSBoundParameters.ContainsKey('StowOutput')) { [bool]$StowOutput } else {
        [bool](Get-Variable -Name ClickMageStowOutput -ValueOnly -ErrorAction SilentlyContinue)
    }
    if ($stow -and !(Get-Command -Name Store-CmLoose -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Dot-source ClickMage-Warehouse.ps1 before enabling output stowing.'
    }
    $options = @{
        AssignUnused = $AssignUnused
        StowOutput = $stow
        HandCapacity = [int]$scale.handCapacity
        BulkTransferBatch = [bool]$scale.bulkTransferBatch
        MaxRounds = $MaxRounds
        WaitForNaturalSeconds = $WaitForNaturalSeconds
        SandStagingPoint = $SandStagingPoint
        TimeScale = [Math]::Max(0.1, $scale.timeScale)
    }
    $available = Complete-CmMaterial -Type $Type -Count $Count -ProcessorId $ProcessorId -Options $options
    [pscustomobject]@{ Type = $Type; Before = $before; Available = $available; Target = $Count }
}

function Invoke-CmOutputStow {
    param([string]$Type, $Map, $Options)

    $hand = $Options.HandCapacity
    if (!$Options.StowOutput -or $hand -lt 1) { return $Map }
    $loose = @($Map.resources | Where-Object {
        $_.type -eq $Type -and $_.collectible
    }).Count
    if ($loose - 14 -lt $hand) { return $Map }

    $room = 0
    foreach ($chest in $Map.buildings.chests) {
        if (($chest.type -eq $Type -and $chest.count -lt 100) -or $chest.count -eq 0) {
            $room += 100 - $chest.count
        }
    }
    $wholeHands = [Math]::Floor([Math]::Min($loose - 14, $room) / $hand)
    if ($wholeHands -lt 1) { return $Map }

    Store-CmLoose -Type $Type -KeepLoose ($loose - $wholeHands * $hand) -MaxNewChests 0 | Out-Null
    return (Get-CmMap)
}

function Get-CmMachines {
    param($Map, $Catalog, [string]$Type, [int]$ProcessorId)

    foreach ($processor in $Map.buildings.processors | Where-Object {
        $_.output -eq $Type -and (!$ProcessorId -or $_.id -eq $ProcessorId)
    }) {
        $storage = $Map.buildings.storages | Where-Object id -eq $processor.inputStorage | Select-Object -First 1
        if (!$storage -or !$processor.ingredients) { continue }
        $shop = $Catalog.processors | Where-Object id -eq $processor.id | Select-Object -First 1
        $recipe = $shop.options | Where-Object key -eq $shop.selected | Select-Object -First 1
        if (!$recipe) { throw "No catalog recipe for $Type processor $($processor.id)." }

        $slots = foreach ($ingredient in $processor.ingredients) {
            $slot = $storage.stored | Where-Object type -eq $ingredient.type | Select-Object -First 1
            if (!$slot -or $ingredient.count -lt 1 -or $slot.limit -lt $ingredient.count) {
                throw "The $Type processor cannot hold a complete batch of $($ingredient.type)."
            }
            [pscustomobject]@{
                Type = $ingredient.type
                Cost = [int]$ingredient.count
                Stored = [int]$slot.count
                Limit = [int]$slot.limit
            }
        }
        $queued = ($slots | ForEach-Object { [Math]::Floor($_.Stored / $_.Cost) } |
            Measure-Object -Minimum).Minimum
        $capacity = ($slots | ForEach-Object { [Math]::Floor($_.Limit / $_.Cost) } |
            Measure-Object -Minimum).Minimum
        [pscustomobject]@{
            Processor = $processor
            Storage = $storage
            Seconds = [Math]::Max(0.1, $recipe.seconds)
            Slots = @($slots)
            Queued = [int]$queued
            Capacity = [int]$capacity
            Planned = [int]$queued
        }
    }
}

function Select-CmUnusedProcessor {
    param($Map, $Catalog, [string]$Type, [int]$ProcessorId)

    foreach ($processor in $Map.buildings.processors | Where-Object {
        !$_.processing -and (!$ProcessorId -or $_.id -eq $ProcessorId) -and (!$_.output -or $ProcessorId)
    }) {
        $storage = $Map.buildings.storages | Where-Object id -eq $processor.inputStorage | Select-Object -First 1
        if (@($storage.stored | Where-Object count -gt 0).Count) { continue }
        $shop = $Catalog.processors | Where-Object id -eq $processor.id | Select-Object -First 1
        $recipe = $shop.options | Where-Object { $_.resource -eq $Type -and $_.available } | Select-Object -First 1
        if ($recipe) {
            Invoke-CmControl -Action recipe -TargetId $processor.id -Recipe $recipe.key | Out-Null
            return $true
        }
    }
    return $false
}

function Complete-CmSand {
    param([int]$Count, $Options)

    $beach = @{ x = 0; y = -18.325 }
    $beachRadius = 33
    $staging = $Options.SandStagingPoint
    if ($staging -and ((Get-CmDistanceSquared $staging $beach) -le $beachRadius * $beachRadius)) {
        throw 'Loose sand staging needs a clear land point outside the beach spawn area.'
    }

    $wait = [Diagnostics.Stopwatch]::StartNew()
    $previous = 0
    for ($round = 0; $round -lt $Options.MaxRounds; $round++) {
        $map = Get-CmMap
        $available = Get-CmAvailable -Type sand -Map $map
        if ($available -ge $Count) { return $available }
        if ($available -gt $previous) { $wait.Restart() }
        $previous = $available
        if ($wait.Elapsed.TotalSeconds -ge $Options.WaitForNaturalSeconds) { break }

        $onBeach = @($map.resources | Where-Object {
            $_.type -eq 'sand' -and $_.collectible -and
            (Get-CmDistanceSquared $_ $beach) -le $beachRadius * $beachRadius
        }).Count
        $destination = $staging
        if (!$destination) {
            $destination = $map.buildings.chests | Where-Object {
                $_.type -eq 'sand' -and $_.count -lt 100
            } | Select-Object -First 1
        }
        if (!$destination) { throw 'Sand staging needs a sand chest with room or a clear land point.' }
        $needed = [Math]::Min($onBeach, $Count - $available)
        if ($needed -gt 0) {
            $moved = Move-CmMaterial -Type sand -From Loose -To $destination -Count $needed -SourcePoint $beach -SourceRadius $beachRadius
            if ($moved.StillHeld) { throw 'Sand staging did not accept the whole hand.' }
            Write-Verbose "Moved $($moved.Delivered) sand inland; $available/$Count currently available."
        }
        Start-Sleep -Milliseconds 650
    }
    $available = Get-CmAvailable -Type sand
    if ($available -ge $Count) { return $available }
    throw "Beach supply stopped at $available of $Count available sand."
}

function Supply-CmFuel {
    param($Machine, $Options, $Trail, [int]$ReserveCharcoal)

    $processor = $Machine.Processor
    if (!$processor.fuelPoint -or $Machine.Planned -lt 1) { return 0 }
    $fuelNeeded = $Machine.Seconds * $Machine.Planned
    if ($processor.processing) {
        $fuelNeeded -= [Math]::Max(0, $Machine.Seconds - $processor.remaining)
    }
    $deficit = $fuelNeeded - $processor.fuel
    if ($deficit -lt 0.15) { return 0 }

    $room = if ($null -ne $processor.fuelLimit -and $null -ne $processor.fuelSlots) {
        $processor.fuelLimit - $processor.fuelSlots
    } else { 5 }
    if ($room -le 0) { return 0 }

    $stock = Get-CmMap
    $availableCharcoal = (Get-CmAvailable -Type charcoal -Map $stock) - $ReserveCharcoal
    if ('charcoal' -notin $Trail) {
        $transfer = [int][Math]::Min($room, [Math]::Ceiling($deficit / 100))
        if ($availableCharcoal -lt $transfer -and $stock.buildings.processors.output -contains 'charcoal') {
            # Keep a small fuel buffer beyond any charcoal already promised to steel recipes.
            $target = $ReserveCharcoal + [Math]::Max(10, $transfer)
            Complete-CmMaterial -Type charcoal -Count $target -Options $Options -Trail $Trail | Out-Null
            $availableCharcoal = (Get-CmAvailable -Type charcoal) - $ReserveCharcoal
        }
        if ($availableCharcoal -gt 0) {
            $shipped = Move-CmMaterial -Type charcoal -To $processor.fuelPoint -Count ([Math]::Min($transfer, $availableCharcoal))
            if ($shipped.Delivered) { return $shipped.Delivered }
        }
    }
    # Wood can start the charcoal kilns and run machines before charcoal is unlocked.
    $transfer = [int][Math]::Min($room, [Math]::Max(1, [Math]::Ceiling($deficit / 10)))
    $woodAvailable = Get-CmAvailable -Type wood -Map $stock
    if ($woodAvailable -lt $transfer) {
        Complete-CmMaterial -Type wood -Count $transfer -Options $Options -Trail $Trail | Out-Null
    }
    (Move-CmMaterial -Type wood -To $processor.fuelPoint -Count $transfer).Delivered
}

function Send-CmLooseInputBatch {
    param($Orders, $Options)

    if (!$Options.BulkTransferBatch -or $Orders.Count -lt 2) { return 0 }
    $stock = @{}
    foreach ($item in (Get-CmMap).resources | Where-Object collectible) { $stock[$item.type]++ }
    $destinations = @{}
    foreach ($order in $Orders | Where-Object Count -gt 0) { $destinations[$order.Type]++ }

    $submitted = [Collections.Generic.List[object]]::new()
    foreach ($order in $Orders | Where-Object Count -gt 0) {
        $share = [Math]::Ceiling([int]$stock[$order.Type] / $destinations[$order.Type])
        $destinations[$order.Type]--
        $amount = [Math]::Min(40, [Math]::Min($order.Count, $share))
        if ($amount -lt 1) { continue }
        $stock[$order.Type] -= $amount
        $submitted.Add(@{
            Order = $order
            Transfer = @{
                x = $order.Storage.point.x; y = $order.Storage.point.y
                resource = $order.Type; count = $amount; from = 'Loose'
            }
        })
        if ($submitted.Count -eq 12) { break }
    }
    if ($submitted.Count -lt 2) { return 0 }

    $batch = Invoke-CmControl -Action shipbatch -Transfers @($submitted | ForEach-Object Transfer)
    $moved = 0
    foreach ($receipt in $batch.receipts) {
        if ($receipt.error) { throw $receipt.error }
        $order = $submitted[[int]$receipt.index].Order
        if ($receipt.result.heldAfter -or $receipt.result.onGround) {
            throw "The batch could not place all $($order.Type) at an intake. $($receipt.result.reason)"
        }
        $delivered = [int]$receipt.result.delivered
        $order.Count -= $delivered
        $moved += $delivered
    }
    $moved
}

function Send-CmInputWave {
    param($Orders, [int]$Count, $Options, $Trail)

    $type = $Orders[0].Type
    Complete-CmMaterial -Type $type -Count $Count -Options $Options -Trail $Trail | Out-Null
    $moved = Send-CmLooseInputBatch $Orders $Options
    foreach ($order in $Orders | Where-Object Count -gt 0) {
        $shipment = Move-CmMaterial -Type $type -To $order.Storage -Count $order.Count
        $moved += $shipment.Delivered
    }
    $moved
}

function Supply-CmInputs {
    param($Orders, $Options, $Trail)

    $moved = Send-CmLooseInputBatch $Orders $Options
    foreach ($ingredient in $Orders | Where-Object Count -gt 0 | Group-Object Type) {
        $planned = $ingredient.Group
        $start = 0
        while ($start -lt $planned.Count) {
            $capacity = [Math]::Max(2 * $Options.HandCapacity, $planned[$start].Count)
            $count = 0
            $end = $start
            while ($end -lt $planned.Count -and $end - $start -lt 12 -and $count + $planned[$end].Count -le $capacity) {
                $count += $planned[$end].Count
                $end++
            }
            $moved += Send-CmInputWave -Orders @($planned[$start..($end - 1)]) -Count $count -Options $Options -Trail $Trail
            $start = $end
        }
    }
    $moved
}

function Complete-CmMaterial {
    param([string]$Type, [int]$Count, [int]$ProcessorId, $Options, [string[]]$Trail = @())

    $map = Invoke-CmOutputStow -Type $Type -Map (Get-CmMap) -Options $Options
    $available = Get-CmAvailable -Type $Type -Map $map
    if ($available -ge $Count) { return $available }
    if ($Type -in $Trail) { throw "A stock recipe cycle requires an existing supply of $Type." }
    $nextTrail = @($Trail) + $Type

    $state = Invoke-CmControl -Action status
    $node = $map.nodes | Where-Object {
        $_.type -eq $Type -and $_.clickable -and $_.clickLevelNeeded -le $state.clickLevel
    } | Select-Object -First 1
    if ($node -and !$ProcessorId) {
        $missing = $Count - (Get-CmAvailable -Type $Type -Map $map -IncludePending)
        if ($missing -gt 0) { Invoke-CmHarvest -Type $Type -Amount $missing | Out-Null }
        for ($poll = 0; $poll -lt 10; $poll++) {
            $map = Get-CmMap
            $available = Get-CmAvailable -Type $Type -Map $map
            if ($available -ge $Count) {
                $map = Invoke-CmOutputStow -Type $Type -Map $map -Options $Options
                return (Get-CmAvailable -Type $Type -Map $map)
            }
            Start-Sleep -Milliseconds 250
        }
        throw "Harvest stopped at $available of $Count available $Type."
    }

    $catalog = Invoke-CmControl -Action catalog
    $machines = @(Get-CmMachines $map $catalog $Type $ProcessorId)
    if (!$machines.Count -and ($Options.AssignUnused -or $ProcessorId)) {
        if (Select-CmUnusedProcessor $map $catalog $Type $ProcessorId) {
            $map = Get-CmMap
            $catalog = Invoke-CmControl -Action catalog
            $machines = @(Get-CmMachines $map $catalog $Type $ProcessorId)
        }
    }
    if (!$machines.Count -and $Type -eq 'sand' -and !$ProcessorId) {
        return (Complete-CmSand -Count $Count -Options $Options)
    }
    if (!$machines.Count) {
        $locked = $map.nodes | Where-Object type -eq $Type | Select-Object -First 1
        if ($locked) { throw "$Type requires click level $($locked.clickLevelNeeded)." }
        throw "No active processor is assigned to $Type. Select an available recipe first."
    }

    $stalled = 0
    $previousSignature = ''
    for ($round = 0; $round -lt $Options.MaxRounds; $round++) {
        $available = Get-CmAvailable -Type $Type -Map $map
        if ($available -ge $Count) { return $available }
        $pending = (Get-CmAvailable -Type $Type -Map $map -IncludePending) - $available
        $missing = [Math]::Max(0, $Count - $available - $pending)
        $machines = @(Get-CmMachines $map $catalog $Type $ProcessorId)
        if (!$machines.Count) { throw "All $Type processors stopped or switched recipes." }

        if ($machines.Count -gt 1) {
            # Reserve the first wave across the active set before filling any one machine.
            $largestSlotCost = ($machines | ForEach-Object { $_.Slots } | Measure-Object Cost -Maximum).Maximum
            $wave = [Math]::Max(1, [Math]::Floor(2 * $Options.HandCapacity / ($machines.Count * $largestSlotCost)))
            foreach ($machine in $machines) {
                $machine.Capacity = [Math]::Min($machine.Capacity, $machine.Queued + $wave)
            }
        }
        $queued = ($machines | Measure-Object -Property Queued -Sum).Sum
        $extra = [Math]::Max(0, $missing - $queued)
        while ($extra -gt 0) {
            $next = $machines | Where-Object { $_.Planned -lt $_.Capacity } |
                Sort-Object { $_.Planned * $_.Seconds } | Select-Object -First 1
            if (!$next) { break }
            $next.Planned++
            $extra--
        }

        $orders = @(foreach ($machine in $machines) {
            foreach ($slot in $machine.Slots) {
                $needed = $machine.Planned * $slot.Cost - $slot.Stored
                if ($needed -gt 0) {
                    [pscustomobject]@{ Type = $slot.Type; Count = $needed; Storage = $machine.Storage }
                }
            }
        })
        $reserveCharcoal = ($orders | Where-Object Type -eq 'charcoal' | Measure-Object Count -Sum).Sum
        $moved = 0
        foreach ($machine in $machines) {
            $moved += Supply-CmFuel $machine $Options $nextTrail $reserveCharcoal
        }
        $moved += Supply-CmInputs $orders $Options $nextTrail

        $finalMap = Invoke-CmOutputStow -Type $Type -Map (Get-CmMap) -Options $Options
        $now = Get-CmAvailable -Type $Type -Map $finalMap
        if ($now -ge $Count) { return $now }
        Write-Verbose "$Type is at $now/$Count available; this round moved $moved inputs or fuel."
        $current = @(Get-CmMachines $finalMap $catalog $Type $ProcessorId)
        $signature = "$now/$pending/" + (($current | ForEach-Object {
            "$($_.Queued):$([Math]::Round($_.Processor.remaining, 1)):$([Math]::Round($_.Processor.fuel, 1))"
        }) -join ',')
        $stalled = if ($moved -eq 0 -and $signature -eq $previousSignature) { $stalled + 1 } else { 0 }
        if ($stalled -ge 5) { throw "$Type production stopped at $now/$Count. Check fuel, input intake, or output piles." }
        $previousSignature = $signature
        $soon = $current | Where-Object {
            $_.Processor.processing -and (!$_.Processor.fuelPoint -or $_.Processor.fuel -gt 0)
        } | ForEach-Object { $_.Processor.remaining } | Measure-Object -Minimum
        $delay = [Math]::Min(3000, [Math]::Max(220, 1000 * $soon.Minimum / $Options.TimeScale))
        if (!$moved -or $now -eq $available) { Start-Sleep -Milliseconds ([int]$delay) }
        $map = Get-CmMap
    }
    $available = Get-CmAvailable -Type $Type -Map $map
    if ($available -ge $Count) { return $available }
    throw "$Type reached $available/$Count before the production round limit."
}
