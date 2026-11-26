. (Join-Path $PSScriptRoot 'ClickMage-Production.ps1')

function Get-CmStorage {
    param([int]$Id)
    (Get-CmMap).buildings.storages | Where-Object id -eq $Id | Select-Object -First 1
}

function Send-CmCost {
    param([int]$StorageId, $Cost)

    foreach ($entry in $Cost) {
        $storage = Get-CmStorage $StorageId
        if (!$storage) { throw "Payment storage $StorageId is unavailable." }
        $slot = $storage.stored | Where-Object type -eq $entry.type
        if (!$slot) { throw "Payment storage does not accept $($entry.type)." }
        if ($slot.limit -lt $entry.count) {
            throw "Payment needs $($entry.count) $($entry.type), but this storage holds $($slot.limit)."
        }
        $remaining = $entry.count - $slot.count
        if ($remaining -le 0) { continue }

        Ensure-CmMaterial -Type $entry.type -Count $remaining -AssignUnused | Out-Null
        $movement = Move-CmMaterial -Type $entry.type -To $storage -Count $remaining
        if ($movement.Delivered -lt $remaining) {
            $current = Get-CmStorage $StorageId
            $updated = $current.stored | Where-Object type -eq $entry.type
            if ($updated -and $updated.count -lt $entry.count) {
                throw "Payment sent $($movement.Delivered) of $remaining $($entry.type). $($movement.Reason)"
            }
        }
        Write-Host "Paid $($movement.Delivered) $($entry.type) through stock storage."
    }
}

function Buy-CmRecipe {
    param([string]$Event)

    $trader = (Invoke-CmControl -Action catalog).trader
    $recipe = $trader.options | Where-Object event -eq $Event | Select-Object -First 1
    if ($recipe.bought) { return }
    if (!$recipe.available) { throw "The trader cannot offer $Event yet." }
    Invoke-CmControl -Action recipe -TargetId $trader.id -Recipe $recipe.key | Out-Null
    Send-CmCost -StorageId $trader.storageId -Cost $recipe.cost
    $result = (Invoke-CmControl -Action catalog).trader.options | Where-Object event -eq $Event
    if (!$result.bought) { throw "The trader has not completed $Event." }
    Write-Host "Trader purchase completed for $Event."
}

function Buy-CmUpgrade {
    param([string]$Type, [int]$Level)

    while ($true) {
        $obelisk = (Invoke-CmControl -Action catalog).obelisk
        $upgrade = $obelisk.options | Where-Object type -eq $Type
        if (!$upgrade.unlocked -or $upgrade.maxLevel -lt $Level) {
            throw "The obelisk cannot reach $Type level $Level."
        }
        if ($upgrade.level -ge $Level) { return }
        Invoke-CmControl -Action upgrade -Upgrade $Type | Out-Null
        Send-CmCost -StorageId $obelisk.storageId -Cost $upgrade.cost
        $result = (Invoke-CmControl -Action catalog).obelisk.options | Where-Object type -eq $Type
        if ($result.level -le $upgrade.level) { throw "The stock upgrade for $Type has not completed." }
        Write-Host "$Type reached level $($result.level)."
    }
}

function Build-CmPlant {
    param([string]$Type, [double]$X, [double]$Y, [string]$Recipe)

    $catalog = Invoke-CmControl -Action catalog
    $plan = $catalog.blueprints | Where-Object type -eq $Type
    if (!$plan.unlocked -or !$plan.bought) { throw "Purchase the $Type blueprint first." }
    foreach ($material in $plan.cost) {
        Ensure-CmMaterial -Type $material.type -Count $material.count -AssignUnused | Out-Null
    }
    $before = Get-CmMap
    $foundation = $before.buildings.blueprints | Where-Object {
        $_.type -eq $Type -and [math]::Abs($_.point.x - $X) -lt 0.5 -and [math]::Abs($_.point.y - $Y) -lt 0.5
    } | Select-Object -First 1
    $storageId = if ($foundation) { $foundation.storage } else {
        (Invoke-CmControl -Action build -Building $Type -X $X -Y $Y).storageId
    }
    Send-CmCost -StorageId $storageId -Cost $plan.cost
    if (!$Recipe) { return }

    $prior = @($before.buildings.processors.id)
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $machine = (Get-CmMap).buildings.processors | Where-Object { $_.id -notin $prior -and
            [math]::Abs($_.point.x - $X) -lt 1.5 -and [math]::Abs($_.point.y - $Y) -lt 1.5 } | Select-Object -First 1
        if ($machine) {
            Invoke-CmControl -Action recipe -TargetId $machine.id -Recipe $Recipe | Out-Null
            Write-Host "Built $Type for $Recipe at ($X, $Y)."
            return $machine.id
        }
        Start-Sleep -Milliseconds 250
    }
    throw "The $Type did not enter the stock processor list."
}

function Set-CmPlantOutput {
    param([int]$Id, [string]$Type)

    $shop = (Invoke-CmControl -Action catalog).processors | Where-Object id -eq $Id
    $recipe = $shop.options | Where-Object { $_.resource -eq $Type -and $_.available } | Select-Object -First 1
    if (!$recipe) { throw "Processor $Id cannot produce $Type." }
    if ($shop.selected -eq $recipe.key) { return }

    for ($attempt = 0; $attempt -lt 24; $attempt++) {
        $machine = (Get-CmMap).buildings.processors | Where-Object id -eq $Id
        if (!$machine) { throw "Processor $Id is absent." }
        if (!$machine.processing) {
            Invoke-CmControl -Action recipe -TargetId $Id -Recipe $recipe.key | Out-Null
            Write-Host "Processor $Id is set to $Type."
            return
        }
        if ($machine.fuelPoint -and $machine.fuel -le 0) {
            Ensure-CmMaterial -Type wood -Count 2 | Out-Null
            Move-CmMaterial -Type wood -To $machine.fuelPoint -Count 2 | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Processor $Id is still finishing its previous batch."
}

function Discover-CmMaterial {
    param([string]$Type)

    $catalog = Invoke-CmControl -Action catalog
    if ($Type -in $catalog.resources) { return }
    Ensure-CmMaterial -Type $Type -Count 1 | Out-Null
    $map = Get-CmMap
    $picked = $null
    foreach ($source in $map.resources | Where-Object { $_.type -eq $Type -and $_.collectible } | Select-Object -First 8) {
        $picked = Invoke-CmControl -Action collect -X $source.x -Y $source.y -Resource $Type -Count 1 -Seconds 2
        if ($picked.heldAfter) { break }
    }
    if (!$picked.heldAfter) { throw "A loose $Type sample could not be picked up." }

    foreach ($point in @($source, @{ x = 2.5; y = -8.5 }, @{ x = 10.5; y = -1.4 })) {
        $drop = Invoke-CmControl -Action drop -X $point.x -Y $point.y -Count 1 -Seconds 2
        if (!$drop.heldAfter) { break }
    }
    if ($drop.heldAfter) { throw "The $Type sample remains in hand." }
    if ($Type -notin (Invoke-CmControl -Action catalog).resources) {
        throw "The game has not recorded discovery of $Type."
    }
}

function Complete-CmPortalStage {
    param([int]$Stage)

    $portal = (Invoke-CmControl -Action catalog).portals | Select-Object -First 1
    if ($portal.stage -gt $Stage -or $portal.finished) { return }
    if ($portal.stage -ne $Stage) { throw "The portal has reached stage $($portal.stage). Expected $Stage." }
    $requirement = $portal.stages | Where-Object stage -eq $Stage
    Send-CmCost -StorageId $portal.storageId -Cost $requirement.cost
    $result = (Invoke-CmControl -Action catalog).portals | Select-Object -First 1
    if ($result.stage -ne ($Stage + 1) -and !$result.finished) { throw "The portal has not advanced from stage $Stage." }
    if (!$result.finished) { Invoke-CmControl -Action save | Out-Null }
    Write-Host "Portal advanced to stage $($result.stage)."
}
