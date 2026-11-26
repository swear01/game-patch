. (Join-Path $PSScriptRoot 'ClickMage-Progress.ps1')

function New-CmWarehouseChest {
    [CmdletBinding()]
    param([string]$Type)

    $ClickMageStowOutput = $false
    $plan = (Invoke-CmControl -Action catalog).blueprints |
        Where-Object type -eq 'storage' | Select-Object -First 1
    if (!$plan.unlocked -or !$plan.bought) { throw 'Unlock the stock Storage blueprint before growing the warehouse.' }
    if ($Type -and (Get-CmAvailable -Type $Type) -lt 1) {
        throw "There is no existing $Type to seed the new chest."
    }

    $map = Get-CmMap
    $oldIds = @($map.buildings.chests.id)
    $oldSites = @($map.buildings.chests) + @($map.buildings.processors) + @($map.buildings.storages) + @($map.buildings.blueprints)
    $prepared = $false
    $storageId = $null
    $placement = $null
    :warehouse for ($column = 0; $column -lt 8; $column++) {
        for ($row = 0; $row -lt 8; $row++) {
            $site = @{ x = 18.45 + 2.25 * $column; y = -4.5 + 2.25 * $row }
            $foundation = $map.buildings.blueprints | Where-Object {
                $_.type -eq 'storage' -and (Get-CmDistanceSquared $_.point $site) -lt 1
            } | Select-Object -First 1
            if ($foundation) {
                $storageId = $foundation.storage
                $placement = $foundation.point
                break warehouse
            }
            $occupied = $oldSites | Where-Object {
                $_.point -and (Get-CmDistanceSquared $_.point $site) -lt 2.25
            } | Select-Object -First 1
            if ($occupied) { continue }

            if (!$prepared) {
                foreach ($material in $plan.cost) {
                    # Keep the stock item used to seed the chest separate from its construction payment.
                    $cost = $material.count + [int]($Type -eq $material.type)
                    Ensure-CmMaterial -Type $material.type -Count $cost -AssignUnused | Out-Null
                }
                $prepared = $true
            }

            try {
                $foundation = Invoke-CmControl -Action build -Building storage -X $site.x -Y $site.y
            } catch {
                if ($_.Exception.Message -notmatch 'blocked placement at this location|outside the playable area') { throw }
                Write-Verbose "Storage placement at ($($site.x), $($site.y)) was blocked."
                continue
            }
            $storageId = $foundation.storageId
            $placement = $foundation.point
            break warehouse
        }
    }
    if (!$storageId) { throw 'No stock placement was available on the warehouse grid.' }
    if (!$prepared -and $Type) {
        $payment = Get-CmStorage $storageId
        $seedCost = $plan.cost | Where-Object type -eq $Type | Select-Object -First 1
        if ($seedCost) {
            $slot = $payment.stored | Where-Object type -eq $Type | Select-Object -First 1
            $left = [Math]::Max(0, $seedCost.count - $slot.count)
            Ensure-CmMaterial -Type $Type -Count ($left + 1) -AssignUnused | Out-Null
        }
    }
    Send-CmCost -StorageId $storageId -Cost $plan.cost

    $chest = $null
    for ($poll = 0; $poll -lt 16; $poll++) {
        $chest = (Get-CmMap).buildings.chests | Where-Object {
            $_.id -notin $oldIds -and (Get-CmDistanceSquared $_.point $placement) -lt 2.25
        } | Sort-Object { Get-CmDistanceSquared $_.point $placement } | Select-Object -First 1
        if ($chest) { break }
        Start-Sleep -Milliseconds 200
    }
    if (!$chest) { throw 'The paid Storage blueprint did not produce a native chest at its placement.' }

    if ($Type -and $chest.count -eq 0) {
        $seed = Move-CmMaterial -Type $Type -To $chest -Count 1
        $chest = (Get-CmMap).buildings.chests | Where-Object id -eq $chest.id | Select-Object -First 1
        if ($seed.Delivered -ne 1 -or $seed.StillHeld -or !$chest -or $chest.type -ne $Type -or $chest.count -lt 1) {
            throw "The native chest did not accept its $Type seed. $($seed.Reason)"
        }
    }
    if ($Type -and $chest.type -ne $Type) {
        throw "New chest $($chest.id) already contains $($chest.type) and has been left intact."
    }
    $chest
}

function Store-CmLoose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [ValidateRange(0, 10000)][int]$KeepLoose = 0,
        [ValidateRange(0, 64)][int]$MaxNewChests = 0
    )

    $map = Get-CmMap
    $built = @()
    $used = @()
    $stored = 0
    $reason = 'Warehouse route limit'
    $roundLimit = 2 * (@($map.buildings.chests).Count + $MaxNewChests + 1)
    for ($round = 0; $round -lt $roundLimit; $round++) {
        $loose = @($map.resources | Where-Object { $_.type -eq $Type -and $_.collectible }).Count
        if ($loose -le $KeepLoose) {
            $reason = 'Loose-stock allowance reached'
            break
        }

        $chest = $map.buildings.chests | Where-Object {
            $_.type -eq $Type -and $_.count -lt 100
        } | Sort-Object count -Descending | Select-Object -First 1
        if (!$chest) {
            $chest = $map.buildings.chests | Where-Object count -eq 0 | Select-Object -First 1
        }
        if (!$chest) {
            if ($built.Count -ge $MaxNewChests) {
                $reason = 'No matching or empty chest room'
                break
            }
            # Track the chest by the native ID, even when construction used an existing blueprint.
            $chest = New-CmWarehouseChest
            $built += $chest.id
            $map = Get-CmMap
            $loose = @($map.resources | Where-Object { $_.type -eq $Type -and $_.collectible }).Count
            if ($loose -le $KeepLoose) {
                $reason = 'Loose-stock allowance reached'
                break
            }
            if ($chest.count -gt 0 -and $chest.type -ne $Type) { continue }
        }

        $amount = if ($chest.count -eq 0) { 1 } else {
            [Math]::Min(100 - $chest.count, $loose - $KeepLoose)
        }
        $shipment = Move-CmMaterial -Type $Type -From Loose -To $chest -Count $amount
        $map = Get-CmMap
        $actual = $map.buildings.chests | Where-Object id -eq $chest.id | Select-Object -First 1
        $confirmed = if ($actual -and $actual.type -eq $Type) {
            [Math]::Max(0, [Math]::Min($shipment.Delivered, $actual.count - $chest.count))
        } else { 0 }
        if ($confirmed) {
            $stored += $confirmed
            if ($chest.id -notin $used) { $used += $chest.id }
        }
        if (!$confirmed -or $shipment.StillHeld) {
            $reason = $shipment.Reason
            break
        }
    }

    $remaining = @($map.resources | Where-Object type -eq $Type)
    [pscustomobject]@{
        Type = $Type
        Stored = $stored
        StillLoose = $remaining.Count
        Pending = @($remaining | Where-Object { !$_.collectible }).Count
        Chests = $used
        Built = $built
        Reason = $reason
    }
}
