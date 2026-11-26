[CmdletBinding()]
param(
    [double]$AlchemyX,
    [double]$AlchemyY,

    [ValidateRange(30, 900)]
    [int]$EndingTimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
if ($PSBoundParameters.ContainsKey('AlchemyX') -ne $PSBoundParameters.ContainsKey('AlchemyY')) {
    throw 'Provide both -AlchemyX and -AlchemyY for a specific construction site.'
}
$alchemySites = if ($PSBoundParameters.ContainsKey('AlchemyX')) {
    @(@{ x = $AlchemyX; y = $AlchemyY })
} else {
    @(
        @{ x = -12; y = 10 }
        @{ x = -18; y = 7 }
        @{ x = -12; y = 4 }
        @{ x = 12; y = 11 }
        @{ x = 20; y = 13 }
        @{ x = 4; y = 4 }
        @{ x = 5; y = -6 }
        @{ x = 15; y = 5 }
        @{ x = 20; y = -5 }
        @{ x = -8; y = -6 }
        @{ x = -16; y = -6 }
    )
}

. (Join-Path $PSScriptRoot 'ClickMage-Warehouse.ps1')
$ClickMageStowOutput = $true

$furnaceOutputs = @('ash', 'charcoal', 'glass', 'ironIngot', 'steelIngot', 'copperIngot')
$forgeOutputs = @('phial', 'crystalDust', 'woodPulp', 'copperWire', 'copperPipe')

function Set-CmLateProducer {
    param([string]$Type, [string[]]$Protect = @())

    $machines = (Invoke-CmControl -Action scan -Kind buildings).buildings.processors
    if ($machines.output -contains $Type) { return }

    $shops = (Invoke-CmControl -Action catalog).processors
    $compatibleIds = @($shops | Where-Object {
        $_.options | Where-Object { $_.resource -eq $Type -and $_.available }
    } | ForEach-Object id)
    $machine = $machines | Where-Object {
        $output = $_.output
        $_.id -in $compatibleIds -and ($output -notin $Protect -or
            @($machines | Where-Object output -eq $output).Count -gt 1)
    } | Sort-Object @{ Expression = { [bool]$_.processing } }, @{ Expression = { [bool]$_.output } } |
        Select-Object -First 1
    if (!$machine) {
        throw "No compatible processor can switch to $Type while preserving the required recipes."
    }
    Set-CmPlantOutput -Id $machine.id -Type $Type
}

function Ensure-CmLateStock {
    param([string]$Type, [int]$Count)

    if ($Count -le 0 -or (Get-CmAvailable -Type $Type) -ge $Count) { return }
    if ($Type -in $forgeOutputs) {
        # Keep phial available while the other forge rotates among the remaining recipes.
        Set-CmLateProducer -Type $Type -Protect @('phial')
    }
    Write-Host "Preparing $Count $Type in stock."
    Ensure-CmMaterial -Type $Type -Count $Count -AssignUnused | Out-Null
}

function Add-CmLateSmelter {
    param([string]$Type)

    $stock = Get-CmMap
    if (@($stock.buildings.processors | Where-Object output -eq $Type).Count -ge 2) { return }
    $recipe = (Invoke-CmControl -Action catalog).processors.options | Where-Object {
        $_.resource -eq $Type -and $_.available
    } | Select-Object -First 1
    if (!$recipe) { throw "The stock smelter cannot produce $Type." }

    $sites = @(@{ x = 7; y = -6 }, @{ x = 12; y = -6 }, @{ x = 12; y = 1 },
        @{ x = 13; y = 4 }, @{ x = 8; y = 5 }, @{ x = -8; y = 6 }, @{ x = 8; y = 12 })
    foreach ($site in $sites) {
        try {
            Build-CmPlant -Type smelter -Recipe $recipe.key -X $site.x -Y $site.y | Out-Null
            return
        } catch {
            if ($_.Exception.Message -notmatch 'blocked placement|outside the playable area|outside the game view') { throw }
        }
    }
    Write-Host "No free site was available for another $Type smelter."
}

function Get-CmLateUnpaidCost {
    param($Cost, [int]$StorageId)

    $storage = if ($StorageId) { Get-CmStorage $StorageId }
    foreach ($item in $Cost) {
        $slot = $storage.stored | Where-Object type -eq $item.type | Select-Object -First 1
        $unpaid = $item.count - $slot.count
        if ($unpaid -gt 0) {
            [pscustomobject]@{ type = $item.type; count = $unpaid }
        }
    }
}

function Get-CmLateAlchemy {
    ((Invoke-CmControl -Action catalog).processors | Where-Object {
        $_.options.resource -contains 'catalyst'
    } | Select-Object -First 1)
}

function Buy-CmLateAlchemyRecipe {
    param([string]$Event)

    $shop = (Invoke-CmControl -Action catalog).trader
    $recipe = $shop.options | Where-Object event -eq $Event | Select-Object -First 1
    if (!$recipe) { throw "The stock trader catalog has no $Event recipe." }
    if ($recipe.bought) { return }
    if (!$recipe.available) { throw "The stock trader cannot offer $Event yet." }
    $storage = if ($shop.selected -eq $recipe.key) { $shop.storageId } else { 0 }
    foreach ($item in (Get-CmLateUnpaidCost -Cost $recipe.cost -StorageId $storage)) {
        Ensure-CmLateStock -Type $item.type -Count $item.count
    }
    Buy-CmRecipe -Event $Event
}

function Complete-CmLateAlchemyBuild {
    param($Sites)

    $alchemy = Get-CmLateAlchemy
    if ($alchemy) { return $alchemy }

    Buy-CmLateAlchemyRecipe -Event unlock_alchemyTable
    $catalog = Invoke-CmControl -Action catalog
    $plan = $catalog.blueprints | Where-Object type -eq 'alchemyTable'
    if (!$plan.unlocked -or !$plan.bought) { throw 'The alchemy table blueprint is unavailable.' }
    $foundation = (Invoke-CmControl -Action scan -Kind buildings).buildings.blueprints |
        Where-Object type -eq 'alchemyTable' | Select-Object -First 1
    $storageId = if ($foundation) { $foundation.storage } else { 0 }
    $cost = @(Get-CmLateUnpaidCost -Cost $plan.cost -StorageId $storageId)
    $catalyst = $catalog.trader.options | Where-Object event -eq 'unlock_alchemyTable_catalyst'
    $wire = ($cost | Where-Object type -eq copperWire).count
    if (!$catalyst.bought) {
        # Keep the wire for the following purchase ready before switching the forge.
        $wire += ($catalyst.cost | Where-Object type -eq copperWire).count
    }
    Ensure-CmLateStock -Type copperWire -Count $wire
    foreach ($item in $cost | Where-Object type -ne copperWire) {
        Ensure-CmLateStock -Type $item.type -Count $item.count
    }

    if (!$storageId) {
        foreach ($point in $Sites) {
            try {
                $site = Invoke-CmControl -Action build -Building alchemyTable -X $point.x -Y $point.y
                $storageId = $site.storageId
                break
            } catch {
                if ($_.Exception.Message -notmatch 'blocked placement|outside the playable area|outside the game view') { throw }
                Write-Verbose "Stock collision check rejected alchemy site ($($point.x), $($point.y))."
            }
        }
        if (!$storageId) { throw 'No proposed alchemy site passed the normal placement check.' }
    }

    Send-CmCost -StorageId $storageId -Cost $plan.cost
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $alchemy = Get-CmLateAlchemy
        if ($alchemy) {
            Write-Host 'The paid alchemy table entered the stock processor list.'
            Invoke-CmControl -Action save | Out-Null
            return $alchemy
        }
        Start-Sleep -Milliseconds 300
    }
    throw 'Alchemy table build was paid but the stock processor did not appear.'
}

function Get-CmLateEssenceNeeds {
    param($Portal)

    $map = Get-CmMap
    $storage = $map.buildings.storages | Where-Object id -eq $Portal.storageId
    foreach ($stage in $Portal.stages | Where-Object { $_.stage -ge [Math]::Max(5, $Portal.stage) }) {
        foreach ($item in $stage.cost) {
            $missing = $item.count - (Get-CmAvailable -Type $item.type -Map $map)
            if ($stage.stage -eq $Portal.stage) {
                $missing -= ($storage.stored | Where-Object type -eq $item.type).count
            }
            if ($missing -gt 0) {
                [pscustomobject]@{ type = $item.type; count = $missing }
            }
        }
    }
}

function Prepare-CmLateAlchemy {
    param($Portal, $Alchemy)

    Buy-CmLateAlchemyRecipe -Event unlock_alchemyTable_catalyst
    $shop = Get-CmLateAlchemy
    $needs = @(Get-CmLateEssenceNeeds $Portal)
    $ingredients = @{ catalyst = 0; phial = 0; crystalDust = 0; woodPulp = 0 }
    foreach ($need in $needs) {
        $recipe = $shop.options | Where-Object { $_.resource -eq $need.type -and $_.available }
        if (!$recipe) { throw "The stock alchemy table cannot produce $($need.type)." }
        foreach ($item in $recipe.cost) {
            if ($ingredients.ContainsKey($item.type)) {
                $ingredients[$item.type] += $item.count * $need.count
            }
        }
    }
    $missingCatalyst = [Math]::Max(0, $ingredients.catalyst - (Get-CmAvailable -Type catalyst))
    if ($missingCatalyst -gt 0) {
        $catalystRecipe = $shop.options | Where-Object { $_.resource -eq 'catalyst' -and $_.available }
        if (!$catalystRecipe) { throw 'The paid catalyst recipe is unavailable at the alchemy table.' }
        foreach ($item in $catalystRecipe.cost) {
            if ($ingredients.ContainsKey($item.type)) {
                $ingredients[$item.type] += $item.count * $missingCatalyst
            }
        }
    }

    foreach ($type in @('phial', 'crystalDust', 'woodPulp')) {
        Ensure-CmLateStock -Type $type -Count $ingredients[$type]
    }
    if ($missingCatalyst -gt 0) {
        Set-CmPlantOutput -Id $Alchemy.id -Type catalyst
        Ensure-CmLateStock -Type catalyst -Count $ingredients.catalyst
    }
    Invoke-CmControl -Action save | Out-Null
}

function Complete-CmLateEnding {
    param([int]$TimeoutSeconds)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $ending = Invoke-CmControl -Action continueending
        if ($ending.completed) {
            if ($ending.scene -ne 'EndScreen' -or !$ending.portalFinished -or
                !$ending.leaveChosen -or !$ending.endScreenComponentId) {
                throw 'The response did not prove the original EndScreen was reached.'
            }
            return $ending
        }
        if ($ending.action) { Write-Host "Original ending action $($ending.action)." }
        Start-Sleep -Milliseconds 400
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    throw "The original ending did not reach EndScreen. Last observed phase: $($ending.phase)."
}

$ending = Invoke-CmControl -Action ending
if ($ending.completed -or $ending.portalFinished) {
    Complete-CmLateEnding -TimeoutSeconds $EndingTimeoutSeconds
    return
}
$catalog = Invoke-CmControl -Action catalog
$portal = $catalog.portals | Select-Object -First 1
if (!$portal -or $portal.stage -lt 4) {
    throw 'Finish portal stages 0–3 before starting the late campaign.'
}
$state = Invoke-CmControl -Action status
$storageUpgrade = $catalog.obelisk.options | Where-Object type -eq buildingStorage
if ($state.clickLevel -lt 4 -or $storageUpgrade.level -lt 7) {
    throw 'The late campaign needs click hardness 4 and building storage 7.'
}
if ($catalog.events -notcontains 'unlock_forge_copper_processing') {
    throw 'Buy the copper processing recipe from the stock trader first.'
}
if ($state.paused -or $state.timeScale -le 0) { throw 'Resume the game before starting.' }

if ($portal.stage -le 5) {
    Store-CmLoose -Type wood -KeepLoose 0 -MaxNewChests 0 | Out-Null
    foreach ($type in @('charcoal', 'ash')) { Add-CmLateSmelter -Type $type }
    Buy-CmUpgrade -Type handsize -Level 5
    Buy-CmUpgrade -Type fuelStorage -Level 2
    Invoke-CmControl -Action save | Out-Null
}

if ($portal.stage -eq 4) {
    $energy = $portal.stages | Where-Object stage -eq 4 | ForEach-Object cost
    $remaining = @(Get-CmLateUnpaidCost -Cost $energy -StorageId $portal.storageId)
    if ($remaining.Count -and (Get-CmAvailable -Type emptyEnergyCrystal) -lt $remaining[0].count) {
        Discover-CmMaterial -Type crystal
        foreach ($type in @('ash', 'charcoal', 'glass', 'emptyEnergyCrystal')) {
            Set-CmLateProducer -Type $type -Protect $furnaceOutputs
        }
        Set-CmLateProducer -Type crystalDust -Protect @('phial')
    }
    Complete-CmPortalStage -Stage 4
    $portal = (Invoke-CmControl -Action catalog).portals | Select-Object -First 1
}

if ($portal.stage -eq 5 -and $storageUpgrade.level -lt 8) {
    Set-CmLateProducer -Type emptyEnergyCrystal -Protect $furnaceOutputs
    Set-CmLateProducer -Type crystalDust -Protect @('phial')
    Buy-CmUpgrade -Type buildingStorage -Level 8
    Invoke-CmControl -Action save | Out-Null
}

if (@(Get-CmLateEssenceNeeds $portal).Count) {
    foreach ($type in $furnaceOutputs) {
        Set-CmLateProducer -Type $type -Protect $furnaceOutputs
    }
    Set-CmLateProducer -Type plank
    Discover-CmMaterial -Type crystal
    Discover-CmMaterial -Type glass
    $alchemy = Complete-CmLateAlchemyBuild -Sites $alchemySites
    Prepare-CmLateAlchemy -Portal $portal -Alchemy $alchemy
}

while (!$portal.finished) {
    $stage = $portal.stage
    if ($stage -lt 5 -or $stage -gt 11) {
        throw "Unexpected stock portal stage $stage."
    }
    $requirement = $portal.stages | Where-Object stage -eq $stage
    foreach ($item in (Get-CmLateUnpaidCost -Cost $requirement.cost -StorageId $portal.storageId)) {
        if ((Get-CmAvailable -Type $item.type) -lt $item.count) {
            $alchemy = Get-CmLateAlchemy
            if (!$alchemy) { throw 'The alchemy table is unavailable.' }
            Set-CmPlantOutput -Id $alchemy.id -Type $item.type
        }
    }
    Complete-CmPortalStage -Stage $stage
    $portal = (Invoke-CmControl -Action catalog).portals | Select-Object -First 1
    if (!$portal -or (!$portal.finished -and $portal.stage -ne ($stage + 1))) {
        throw "The live portal did not confirm advancement from stage $stage."
    }
}

Complete-CmLateEnding -TimeoutSeconds $EndingTimeoutSeconds
