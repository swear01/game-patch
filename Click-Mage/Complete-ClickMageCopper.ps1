[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClickMage-Warehouse.ps1')
$ClickMageStowOutput = $true

function Get-CopperForgeRecipe {
    param([string]$Type)

    $shops = (Invoke-CmControl -Action catalog).processors
    $shop = $shops | Where-Object id -eq $copperForgeId | Select-Object -First 1
    $shop.options | Where-Object { $_.resource -eq $Type -and $_.available } | Select-Object -First 1
}

function Ensure-CopperMaterial {
    param([string]$Type, [int]$Count, [string[]]$Trail = @())

    $map = Get-CmMap
    $available = Get-CmAvailable -Type $Type -Map $map
    if ($available -ge $Count) { return }
    if ($Type -in $Trail) { throw "The stock forge recipe chain ran out of $Type." }

    $recipe = Get-CopperForgeRecipe $Type
    if ($recipe) {
        foreach ($ingredient in $recipe.cost) {
            if (Get-CopperForgeRecipe $ingredient.type) {
                # The same forge may be needed for the ingredient before switching to this recipe.
                $required = ($Count - $available) * $ingredient.count
                Ensure-CopperMaterial $ingredient.type $required -Trail (@($Trail) + $Type)
            }
        }
        $current = (Get-CmMap).buildings.processors | Where-Object output -eq $Type
        if (!$current) {
            $forgeId = if ($Type -eq 'steelBeam') { $steelForgeId } else { $copperForgeId }
            Set-CmPlantOutput -Id $forgeId -Type $Type
        }
    }

    Ensure-CmMaterial -Type $Type -Count $Count -AssignUnused | Out-Null
}

function Prepare-CopperPayment {
    param($Cost, [int]$PaymentStorageId)

    $storage = if ($PaymentStorageId) { Get-CmStorage $PaymentStorageId }
    $requirements = foreach ($entry in $Cost) {
        $slot = $storage.stored | Where-Object type -eq $entry.type | Select-Object -First 1
        $remaining = [int]$entry.count - [int]$slot.count
        if ($remaining -gt 0) { [pscustomobject]@{ Type = $entry.type; Count = $remaining } }
    }
    # Process the finished parts before reserving the raw ingots for the same payment.
    $requirements = @($requirements | Sort-Object {
        switch ($_.Type) {
            'copperPipe' { 0 }
            'copperSheet' { 1 }
            'copperWire' { 2 }
            default { 3 }
        }
    })
    for ($round = 0; $round -lt 3; $round++) {
        foreach ($requirement in $requirements) {
            Ensure-CopperMaterial $requirement.Type $requirement.Count
        }
        $stock = Get-CmMap
        $shortages = @($requirements | Where-Object {
            (Get-CmAvailable -Type $_.Type -Map $stock) -lt $_.Count
        })
        if (!$shortages.Count) { return }
    }
    throw "Could not buffer the required stock payment for $($shortages.Type -join ', ')."
}

function Buy-CopperUpgrade {
    param([string]$Type, [int]$Level)

    while ($true) {
        $obelisk = (Invoke-CmControl -Action catalog).obelisk
        $upgrade = $obelisk.options | Where-Object type -eq $Type
        if (!$upgrade.unlocked -or $upgrade.maxLevel -lt $Level) {
            throw "The obelisk cannot reach $Type level $Level."
        }
        if ($upgrade.level -ge $Level) { return }
        $storageId = if ($obelisk.selected -eq $Type) { $obelisk.storageId } else { 0 }
        Prepare-CopperPayment -Cost $upgrade.cost -PaymentStorageId $storageId
        Buy-CmUpgrade -Type $Type -Level ($upgrade.level + 1)
    }
}

function Start-CopperSmelters {
    param([int]$Wanted = 4)

    $catalog = Invoke-CmControl -Action catalog
    $stock = Get-CmMap
    $copperSmelters = @($stock.buildings.processors | Where-Object output -eq 'copperIngot').Count
    if ($copperSmelters -ge $Wanted) { return }

    $free = $stock.buildings.processors | Where-Object {
        !$_.output -and !$_.processing -and $_.name -like 'Smelter*'
    }
    foreach ($machine in $free) {
        Set-CmPlantOutput -Id $machine.id -Type copperIngot
        $copperSmelters++
        if ($copperSmelters -ge $Wanted) { return }
    }

    $recipe = $catalog.processors.options | Where-Object { $_.resource -eq 'copperIngot' -and $_.available } |
        Select-Object -First 1
    if (!$recipe) { throw 'The stock smelter catalog does not have copper ingots available.' }

    $candidates = @(
        @{ x = 7; y = -10 }, @{ x = 12; y = -10 }, @{ x = 17; y = -10 }, @{ x = 22; y = -10 },
        @{ x = 7; y = -13 }, @{ x = 12; y = -13 }, @{ x = 17; y = -13 }, @{ x = 22; y = -13 },
        @{ x = 18; y = 6 }, @{ x = 23; y = 6 }
    )
    foreach ($point in $candidates) {
        $occupied = (Get-CmMap).buildings.processors | Where-Object {
            (Get-CmDistanceSquared $_.point $point) -lt 6.25
        } | Select-Object -First 1
        if ($occupied) { continue }
        try {
            Build-CmPlant -Type smelter -X $point.x -Y $point.y -Recipe $recipe.key | Out-Null
        } catch {
            if ($_.Exception.Message -notmatch 'blocked placement|outside the playable area|outside the game view') {
                throw
            }
            Write-Verbose "Stock placement rejected ($($point.x), $($point.y))."
            continue
        }
        $copperSmelters++
        if ($copperSmelters -ge $Wanted) { return }
    }
    if (!$copperSmelters) { throw 'Stock placement did not allow any copper smelter on the planned sites.' }
    Write-Host "Continuing with $copperSmelters copper smelter."
}

$catalog = Invoke-CmControl -Action catalog
$portal = $catalog.portals | Select-Object -First 1
$hardness = $catalog.obelisk.options | Where-Object type -eq 'clickHardness'
$storage = $catalog.obelisk.options | Where-Object type -eq 'buildingStorage'
if (!$portal -or $portal.stage -lt 2 -or $hardness.level -lt 3 -or $storage.level -lt 4) {
    throw 'Copper production requires portal stage 2, click hardness 3, and building storage level 4.'
}
if (($portal.stage -ge 4 -or $portal.finished) -and $hardness.level -ge 4 -and $storage.level -ge 7) {
    Write-Host "Copper milestones already complete at portal stage $($portal.stage)."
    return
}

$stock = Get-CmMap
$forgeShops = @($catalog.processors | Where-Object { $_.options.resource -contains 'steelBeam' })
$forges = @($stock.buildings.processors | Where-Object id -in $forgeShops.id)
$steelForge = $forges | Where-Object output -eq 'steelBeam' | Select-Object -First 1
if (!$steelForge) { $steelForge = $forges | Where-Object output -ne 'ironPlate' | Select-Object -First 1 }
$copperForge = $forges | Where-Object id -ne $steelForge.id | Select-Object -First 1
if (!$steelForge -or !$copperForge) { throw 'Two active stock forges are required for this production plan.' }
$steelForgeId = $steelForge.id
$copperForgeId = $copperForge.id

Discover-CmMaterial -Type copperOre
Buy-CopperUpgrade -Type buildingStorage -Level 6

$trader = (Invoke-CmControl -Action catalog).trader
$copperOrder = $trader.options | Where-Object event -eq 'unlock_forge_copper_processing'
if (!$copperOrder.bought) {
    if (!$copperOrder.available) { throw 'The stock trader has not offered copper processing yet.' }
    $storageId = if ($trader.selected -eq $copperOrder.key) { $trader.storageId } else { 0 }
    Prepare-CopperPayment -Cost $copperOrder.cost -PaymentStorageId $storageId
    Buy-CmRecipe -Event $copperOrder.event
    Invoke-CmControl -Action save | Out-Null
}

Start-CopperSmelters
Buy-CopperUpgrade -Type buildingStorage -Level 7

foreach ($stage in 2,3) {
    $portal = (Invoke-CmControl -Action catalog).portals | Select-Object -First 1
    if ($portal.stage -gt $stage -or $portal.finished) { continue }
    if ($portal.stage -ne $stage) { throw "The stock portal is at stage $($portal.stage), expected $stage." }
    $requirements = $portal.stages | Where-Object stage -eq $stage
    Prepare-CopperPayment -Cost $requirements.cost -PaymentStorageId $portal.storageId
    Complete-CmPortalStage -Stage $stage
}

Buy-CopperUpgrade -Type clickHardness -Level 4
Invoke-CmControl -Action save | Out-Null

$catalog = Invoke-CmControl -Action catalog
$portal = $catalog.portals | Select-Object -First 1
$hardness = $catalog.obelisk.options | Where-Object type -eq 'clickHardness'
$storage = $catalog.obelisk.options | Where-Object type -eq 'buildingStorage'
if ($portal.stage -lt 4 -or $hardness.level -lt 4 -or $storage.level -lt 7) {
    throw 'The stock game has not recorded all copper milestones.'
}
[pscustomobject]@{ PortalStage = $portal.stage; ClickHardness = $hardness.level; BuildingStorage = $storage.level }
