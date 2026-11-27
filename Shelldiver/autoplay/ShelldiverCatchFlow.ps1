function Compare-NativeCatchPipeline($Before, $After) {
    if (!$Before.catchPipeline -or !$After.catchPipeline -or !$Before.storageAutoOutput -or !$After.storageAutoOutput -or
        $Before.transmutatorOutputType -ne $After.transmutatorOutputType -or
        $Before.transmutatorAutoOutput -ne $After.transmutatorAutoOutput) { return }
    $credited = ([decimal]$After.shellCoins-[decimal]$Before.shellCoins)+
        ([decimal]$After.storeShellCoins-[decimal]$Before.storeShellCoins)
    $netDecrease = $Before.catchPipeline.count-$After.catchPipeline.count
    if ($credited -lt 0 -or $netDecrease -lt 0 -or ($netDecrease -gt 0 -and $credited -le 0)) { return }
    foreach ($id in $After.catchPipeline.species.Keys) {
        if ($After.catchPipeline.species[$id] -gt $Before.catchPipeline.species[$id]) { return }
    }
    $stages = [ordered]@{}
    foreach ($name in $Before.catchPipeline.inventories.Keys) {
        $stages[$name] = $After.catchPipeline.inventories[$name].count-$Before.catchPipeline.inventories[$name].count
    }
    return @{
        beforeHash=$Before.sha256;afterHash=$After.sha256;stageDeltas=$stages
        beforeTracked=$Before.catchPipeline.count;afterTracked=$After.catchPipeline.count
        exactInventoryConservation=$netDecrease -eq 0
        unmatchedFishDecrease=$netDecrease;creditedShells=$credited
    }
}
