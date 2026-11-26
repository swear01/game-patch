# Dot-source this file before using the logistics commands.
$script:ClickMageControlClient = Join-Path $PSScriptRoot 'Invoke-ClickMageControl.ps1'

function Invoke-CmControl {
    & $script:ClickMageControlClient @args
}

function Get-CmMap {
    Invoke-CmControl -Action scan -Kind all
}

function Get-CmDistanceSquared {
    param($Left, $Right)
    $dx = $Left.x - $Right.x
    $dy = $Left.y - $Right.y
    $dx * $dx + $dy * $dy
}

function Invoke-CmHarvest {
    [CmdletBinding(DefaultParameterSetName = 'Clicks')]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory, ParameterSetName = 'Clicks')][ValidateRange(1, 5000)][int]$Clicks,
        [Parameter(Mandatory, ParameterSetName = 'Amount')][ValidateRange(1, 2000)][int]$Amount,
        $Near,
        [ValidateRange(0.1, 30)][double]$SourceRadius = 8
    )

    $state = Invoke-CmControl -Action status
    $nodes = (Invoke-CmControl -Action scan -Kind nodes).nodes
    $eligible = $nodes | Where-Object {
        $_.type -eq $Type -and $_.clickable -and $_.clickLevelNeeded -le $state.clickLevel
    }
    $node = if ($Near) {
        $eligible | Sort-Object { Get-CmDistanceSquared $_.point $Near } | Select-Object -First 1
    } else {
        $eligible | Select-Object -First 1
    }
    if (!$node) { throw "No $Type node is available at click level $($state.clickLevel)." }

    $countAttribute = (Get-Command $script:ClickMageControlClient).Parameters['Count'].Attributes |
        Where-Object { $_ -is [Management.Automation.ValidateRangeAttribute] } | Select-Object -First 1
    $maxBatch = if ($countAttribute) { [int]$countAttribute.MaxRange } else { 40 }
    $before = $null
    $previous = 0
    $gain = $null
    $emptyBatches = 0
    $remaining = $Clicks
    $clickBudget = $Clicks
    $radiusSquared = $SourceRadius * $SourceRadius
    if ($PSCmdlet.ParameterSetName -eq 'Amount') {
        $before = @((Invoke-CmControl -Action scan -Kind resources).resources | Where-Object {
            $_.type -eq $Type -and (Get-CmDistanceSquared $_ $node.point) -le $radiusSquared
        }).Count
        $gain = 0
        $remaining = [Math]::Ceiling($Amount * $node.clicksNeededForResource / $state.clickPower)
        $clickBudget = 3 * $remaining + $maxBatch
    }

    $sent = 0
    while ($remaining -gt 0 -and $sent -lt $clickBudget) {
        $batch = [int][Math]::Min($maxBatch, [Math]::Min($remaining, $clickBudget - $sent))
        $result = Invoke-CmControl -Action click -X $node.point.x -Y $node.point.y -Count $batch -TimeoutSeconds 50
        if ($result.clicks -lt 1) { throw "No clicks registered at the $Type node." }
        $sent += $result.clicks
        $remaining -= $result.clicks
        if ($null -eq $before) { continue }

        $after = @((Invoke-CmControl -Action scan -Kind resources).resources | Where-Object {
            $_.type -eq $Type -and (Get-CmDistanceSquared $_ $node.point) -le $radiusSquared
        }).Count
        $gain = $after - $before
        if ($gain -ge $Amount) { break }
        $emptyBatches = if ($gain -le $previous) { $emptyBatches + 1 } else { 0 }
        if ($emptyBatches -ge 2) { break }
        $previous = $gain
        $remaining = [Math]::Ceiling(($Amount - $gain) * $node.clicksNeededForResource / $state.clickPower)
    }

    [pscustomobject]@{ Type = $Type; Clicks = $sent; SpawnedNearNode = $gain; Point = $node.point }
}

function Get-CmReceiver {
    param($Map, $Point, [string]$Type, [bool]$StorageExpected)

    $storage = $Map.buildings.storages | Where-Object {
        (Get-CmDistanceSquared $_.point $Point) -lt 0.01
    } | Select-Object -First 1
    if ($storage) {
        $slot = $storage.stored | Where-Object type -eq $Type | Select-Object -First 1
        if (!$slot) {
            return @{ StoresItems = $true; IsStorage = $true; Room = 0; Reason = 'Destination does not accept this material' }
        }
        return @{ StoresItems = $true; IsStorage = $true; Room = $slot.limit - $slot.count; Reason = 'Destination is full' }
    }
    if ($StorageExpected) {
        return @{ StoresItems = $true; IsStorage = $true; Room = 0; Reason = 'Destination storage is no longer active' }
    }

    $chest = $Map.buildings.chests | Where-Object {
        (Get-CmDistanceSquared $_.point $Point) -lt 0.01
    } | Select-Object -First 1
    if ($chest) {
        if ($chest.count -gt 0 -and $chest.type -ne $Type) {
            return @{ StoresItems = $true; Room = 0; Reason = 'Destination does not accept this material' }
        }
        # StorageBuilding in the supported build accepts a maximum of 100 items.
        return @{ StoresItems = $true; Room = 100 - $chest.count; Reason = 'Destination is full' }
    }

    $fuel = $Map.buildings.processors | Where-Object {
        $_.fuelPoint -and (Get-CmDistanceSquared $_.fuelPoint $Point) -lt 0.01
    } | Select-Object -First 1
    if ($fuel) {
        $room = if ($null -ne $fuel.fuelLimit -and $null -ne $fuel.fuelSlots) {
            $fuel.fuelLimit - $fuel.fuelSlots
        } else { [int]::MaxValue }
        return @{ StoresItems = $true; Room = $room; Reason = 'Destination fuel storage is full' }
    }
    return @{ StoresItems = $false; Room = [int]::MaxValue }
}

function Get-CmSourceChests {
    param($Map, [string]$Type, $Destination, $SourcePoint, [double]$SourceRadiusSquared, [hashtable]$Skipped)

    $Map.buildings.chests | Where-Object {
        $_.type -eq $Type -and $_.count -gt 0 -and !$Skipped.ContainsKey($_.id) -and
        (Get-CmDistanceSquared $_.point $Destination) -gt 0.3 -and
        (!$SourcePoint -or (Get-CmDistanceSquared $_.point $SourcePoint) -le $SourceRadiusSquared)
    }
}

function Find-CmMaterialSource {
    param(
        $Map, [string]$Type, [string]$From, $Destination, $SourcePoint, [double]$SourceRadius,
        [int]$Wanted, [bool]$TypedPickup, [hashtable]$Skipped
    )

    $source = $null
    $sourceRadiusSquared = $SourceRadius * $SourceRadius
    if ($From -ne 'Chest') {
        $loose = @($Map.resources | Where-Object {
            $_.collectible -and (Get-CmDistanceSquared $_ $Destination) -gt 0.3
        })
        $candidates = @($loose | Where-Object {
            $_.type -eq $Type -and !$Skipped.ContainsKey($_.id) -and
            (!$SourcePoint -or (Get-CmDistanceSquared $_ $SourcePoint) -le $sourceRadiusSquared)
        })
        $itemsToScore = if ($TypedPickup) { $candidates } else { $loose }
        foreach ($target in $candidates | Select-Object -First 100) {
            $pile = 0
            $other = 0
            foreach ($item in $itemsToScore) {
                $dx = $item.x - $target.x
                $dy = $item.y - $target.y
                if ($dx * $dx + $dy * $dy -ge 4) { continue }
                if ($item.type -eq $Type) { $pile++ } else { $other++ }
            }
            if (!$source -or $other -lt $source.Other -or ($other -eq $source.Other -and $pile -gt $source.Pile)) {
                $source = @{ Key = $target.id; Point = $target; Other = $other; Pile = $pile }
            }
            if ($source.Pile -ge $Wanted -and $source.Other -eq 0) { break }
        }
    }
    if ($From -ne 'Loose' -and (!$source -or $source.Other -gt 0 -or ($TypedPickup -and $source.Pile -lt $Wanted))) {
        $chest = Get-CmSourceChests $Map $Type $Destination $SourcePoint $sourceRadiusSquared $Skipped |
            Sort-Object count -Descending | Select-Object -First 1
        if ($chest -and (!$source -or $source.Other -gt 0 -or $chest.count -gt $source.Pile)) {
            $source = @{ Key = $chest.id; Point = $chest.point; Other = 0; Pile = $chest.count; Chest = $true }
        }
    }
    return $source
}

function Move-CmMaterial {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$To,
        [Parameter(Mandatory)][ValidateRange(1, 5000)][int]$Count,
        [ValidateSet('Any', 'Loose', 'Chest')][string]$From = 'Any',
        $SourcePoint,
        [ValidateRange(0.1, 1000)][double]$SourceRadius = 8,
        [ValidateRange(0.1, 6)][double]$CollectSeconds = 3,
        [ValidateRange(1, 240)][int]$MaxTrips = 24,
        $MixedDrop
    )

    $destination = if ($To.point) { $To.point } else { $To }
    if ($null -eq $destination.x -or $null -eq $destination.y) {
        throw 'Provide a destination point or a building from Get-CmMap.'
    }
    $state = Invoke-CmControl -Action status
    if (@($state.held).Count) { throw 'Empty the hand before starting a material route.' }
    $clientParameters = (Get-Command $script:ClickMageControlClient).Parameters
    $typedPickup = $clientParameters.ContainsKey('Resource')
    $useBulk = $From -ne 'Chest' -and $state.bulkTransfer -and $clientParameters.ContainsKey('From')
    $map = Get-CmMap
    $delivered = 0
    $overflow = 0
    $trips = 0
    $pickupAttempts = 0
    $bulkCalls = 0
    $heldCount = 0
    $skipped = @{}
    $reason = 'Trip limit'
    $requiresStorage = [bool]$To.stored

    :route while ($trips -lt $MaxTrips) {
        if ($delivered -ge $Count) {
            $reason = 'Requested amount reached'
            break
        }

        $receiver = Get-CmReceiver $map $destination $Type $requiresStorage
        $requiresStorage = $requiresStorage -or $receiver.IsStorage
        if ($receiver.Room -le 0) {
            $reason = $receiver.Reason
            break
        }

        $bulkCount = [Math]::Min(40, [Math]::Min($Count - $delivered, $receiver.Room))
        $shipLoose = $useBulk
        if ($shipLoose -and $From -eq 'Any' -and $typedPickup) {
            $radiusSquared = $SourceRadius * $SourceRadius
            $chest = Get-CmSourceChests $map $Type $destination $SourcePoint $radiusSquared $skipped | Select-Object -First 1
            if ($chest) {
                $eligibleLoose = @($map.resources | Where-Object {
                    $_.type -eq $Type -and $_.collectible -and
                    (Get-CmDistanceSquared $_ $destination) -gt 0.3 -and
                    (!$SourcePoint -or (Get-CmDistanceSquared $_ $SourcePoint) -le $radiusSquared)
                } | Select-Object -First $bulkCount).Count
                $shipLoose = $eligibleLoose -ge $bulkCount
            }
        }
        if ($shipLoose) {
            $shipParameters = @{
                Action = 'ship'; Resource = $Type; X = $destination.x; Y = $destination.y
                Count = $bulkCount; From = 'Loose'
            }
            if ($SourcePoint) {
                $shipParameters.SourceX = $SourcePoint.x
                $shipParameters.SourceY = $SourcePoint.y
                $shipParameters.SourceRadius = $SourceRadius
            }
            $shipment = Invoke-CmControl @shipParameters
            $bulkCalls++
            if ($shipment.picked -gt 0) { $trips++ }
            $delivered += [int]$shipment.delivered
            $overflow += [int]$shipment.onGround
            $heldCount = [int]$shipment.heldAfter
            Write-Verbose "Bulk moved $($shipment.delivered) $Type; $delivered delivered, $overflow loose."
            if ($heldCount -gt 0 -or $shipment.onGround -gt 0 -or $shipment.reason -like 'Destination*') {
                $reason = $shipment.reason
                break
            }
            if ($delivered -ge $Count) {
                $reason = 'Requested amount reached'
                break
            }
            if ($shipment.reason -in @('No matching source remains', 'Waiting for stock chest pickup cooldown')) {
                $useBulk = $false
            } elseif ($shipment.delivered -le 0) {
                $reason = $shipment.reason
                break
            }
            $map = Get-CmMap
            continue
        }

        $noSource = $false
        $handGoal = [Math]::Min($state.handCapacity, $Count - $delivered)
        $pickupLimit = if ($typedPickup) { $handGoal + 5 } else { 1 }
        for ($index = 0; $index -lt $pickupLimit; $index++) {
            $wanted = [Math]::Min($handGoal, $receiver.Room) - $heldCount
            if ($wanted -le 0) { break }
            $source = Find-CmMaterialSource $map $Type $From $destination $SourcePoint $SourceRadius $wanted $typedPickup $skipped
            if (!$source) {
                $noSource = $true
                break
            }
            $pickupAttempts++
            $point = $source.Point
            $duration = if ($source.Chest -and $typedPickup) { 6 } elseif ($source.Other -gt 0) {
                [Math]::Min(0.15, $CollectSeconds)
            } else { $CollectSeconds }
            if ($typedPickup) {
                $requested = [Math]::Min($wanted, $source.Pile)
                $picked = Invoke-CmControl -Action collect -X $point.x -Y $point.y -Seconds $duration -Resource $Type -Count $requested
            } else {
                $picked = Invoke-CmControl -Action collect -X $point.x -Y $point.y -Seconds $duration
            }
            if ($picked.heldAfter -le $heldCount) { $skipped[$source.Key] = $true }
            $heldCount = [int]$picked.heldAfter
            $map = Get-CmMap
            $receiver = Get-CmReceiver $map $destination $Type $requiresStorage
            if ($receiver.Room -le 0) { break }
        }
        if ($heldCount -eq 0) {
            if (!$typedPickup -and !$noSource -and $pickupAttempts -lt $MaxTrips) { continue }
            $reason = if ($receiver.Room -le 0) { $receiver.Reason } elseif ($noSource) { 'No matching source remains' } else { 'No matching items could be picked up' }
            break
        }

        $mixed = !$typedPickup -and @((Invoke-CmControl -Action status).held | Where-Object type -ne $Type).Count
        if ($mixed) {
            if ($MixedDrop) {
                $ground = Invoke-CmControl -Action drop -X $MixedDrop.x -Y $MixedDrop.y -Seconds 6
                if ($ground.heldAfter) { throw 'The mixed pile could not be placed on the staging point.' }
                $heldCount = 0
                $reason = 'Mixed pickup placed at the staging point'
            } else {
                $reason = 'Mixed pickup remains in hand'
            }
            break
        }

        $trips++
        while ($heldCount -gt 0) {
            $dropCount = [Math]::Min($heldCount, [Math]::Min($receiver.Room, $Count - $delivered))
            if ($dropCount -le 0) {
                $stopReason = if ($receiver.Room -le 0) { $receiver.Reason } else { 'Requested amount reached' }
                $reason = "$stopReason; $heldCount still held"
                break route
            }
            $nearDestination = @($map.resources | Where-Object {
                $_.type -eq $Type -and (Get-CmDistanceSquared $_ $destination) -le 0.3
            }).id
            $dropParameters = @{ Action = 'drop'; X = $destination.x; Y = $destination.y; Seconds = 6 }
            if ($typedPickup) { $dropParameters.Count = $dropCount }
            $dropped = Invoke-CmControl @dropParameters
            $putDown = $heldCount - $dropped.heldAfter
            $heldCount = [int]$dropped.heldAfter
            if ($putDown -le 0) {
                $reason = "No items could be placed at the destination; $heldCount still held"
                break route
            }
            $map = Get-CmMap
            $droppedOnGround = 0
            if ($receiver.StoresItems) {
                $droppedOnGround = @($map.resources | Where-Object {
                    $_.type -eq $Type -and $_.id -notin $nearDestination -and
                    (Get-CmDistanceSquared $_ $destination) -le 0.3
                }).Count
            }
            $overflow += $droppedOnGround
            $delivered += [Math]::Max(0, $putDown - $droppedOnGround)
            if ($droppedOnGround -ge $putDown) {
                $reason = 'Destination rejected the delivery'
                break route
            }
            $receiver = Get-CmReceiver $map $destination $Type $requiresStorage
        }
        Write-Verbose "Moved $Type to ($($destination.x), $($destination.y)). Delivered $delivered, loose at destination $overflow."
        if ($noSource) {
            $reason = 'No matching source remains'
            break
        }
    }
    if ($delivered -ge $Count -and $heldCount -eq 0) { $reason = 'Requested amount reached' }
    [pscustomobject]@{
        Type = $Type; Delivered = $delivered; LooseAtDestination = $overflow; Trips = $trips
        PickupAttempts = $pickupAttempts; BulkCalls = $bulkCalls; StillHeld = $heldCount; Reason = $reason
    }
}
