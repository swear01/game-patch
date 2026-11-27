# Dot-source from Invoke-ShelldiverDive.ps1 after loading its native helpers.
function Get-MagmaIIReserve([double]$TravelDistance, [double]$FramesPerPixel, [int]$ActionFrames = 0) {
    $travelFrames = [Math]::Ceiling($TravelDistance * $FramesPerPixel) + 54
    $actionBudget = if ($ActionFrames -gt 0) { $ActionFrames + 30 } else { 0 }
    # Magma II drains 7,000 O2 per 30 frames. Reserve two ticks and one contact.
    return 7000 * ([Math]::Ceiling(($travelFrames + $actionBudget) / 30) + 2) + 20000
}

function Get-MagmaIIWestExit($State, $Position, $Anchor, $Route) {
    if (Test-OceanSegment $State.room $Position $Anchor 18) {
        return @{ point=$Anchor; distance=(Get-Distance $Position $Anchor) }
    }
    $best = $null
    $previous = $Anchor
    $knownDistance = 0.0
    foreach ($pivot in $Route) {
        if (!(Test-OceanSegment $State.room $previous $pivot 18)) { break }
        $knownDistance += Get-Distance $previous $pivot
        $previous = $pivot
        $step = Get-Distance $Position $pivot
        if ($step -lt 14 -or !(Test-OceanSegment $State.room $Position $pivot 18)) { continue }
        $distance = $step + $knownDistance
        if (!$best -or $distance -lt $best.distance) {
            $best = @{ point=$pivot; distance=$distance }
        }
    }
    return $best
}


function Get-MagmaIIReturnStep($State, $Anchor, $Route) {
    $from = $State.scene.player
    $exit = Get-MagmaIIWestExit $State $from $Anchor $Route
    $margin = if (Test-OceanSegment $State.room $from $from 18) { 18 } else { 8 }
    $nearest = Get-MagmaNearestFishDistance $State $from
    $directions = @{x=1;y=0}, @{x=1;y=1}, @{x=0;y=1}, @{x=-1;y=1},
        @{x=-1;y=0}, @{x=-1;y=-1}, @{x=0;y=-1}, @{x=1;y=-1}
    $bestExit = if ($exit) { $exit.distance } else { Get-Distance $from $Anchor }
    foreach ($clearance in 100,60) {
        if ($clearance -eq 60 -and $nearest -ge 112 -and $exit) { break }
        $best = $null
        $bestScore = [double]::NegativeInfinity
        foreach ($heading in $directions) {
            foreach ($stride in 24,16,10) {
                $toward = @{ x=($from.x + $heading.x * $stride); y=($from.y + $heading.y * $stride) }
                $forecast = @{
                    x=($from.x + $heading.x * ($stride + 10))
                    y=($from.y + $heading.y * ($stride + 10))
                }
                if (!(Test-OceanSegment $State.room $from $forecast $margin) -or
                    !(Test-MagmaRetreatPulseFishClear $State $from $forecast $clearance)) { continue }
                $nextExit = Get-MagmaIIWestExit $State $toward $Anchor $Route
                $forecastExit = Get-MagmaIIWestExit $State $forecast $Anchor $Route
                if (!$nextExit -or !$forecastExit) { continue }
                $gain = $bestExit - $nextExit.distance
                $separation = if ([double]::IsInfinity($nearest)) { 0.0 } else {
                    (Get-MagmaNearestFishDistance $State $toward) - $nearest
                }
                if ($exit -and $gain -lt 1 -and ($clearance -ne 60 -or $separation -lt 6)) { continue }
                $score = $gain + $(if ($clearance -eq 60) { 2.0 * $separation } else { 0.1 * $separation })
                if ($score -gt $bestScore) {
                    $bestScore = $score
                    $best = @{ point=$toward; clearance=$clearance }
                }
            }
        }
        if ($best) { return $best }
    }
    return $null
}

function Get-MagmaIIResourcePlan($State, [double]$AimRange, [int]$ShotFrames) {
    $player = $State.scene.player
    $anchor = Get-LiveSubmarine $State
    $resources = @($State.targets.resources | Where-Object { $null -ne $_.x -and $_.y -ge 208 -and $_.y -le 352 })
    $lanes = @(
        @{points=@(@{x=506;y=81},@{x=396;y=81},@{x=282;y=81},@{x=154;y=81},@{x=148;y=172})
          bends=@(@{x=156;y=212},@{x=145;y=220},@{x=170;y=234},@{x=276;y=268})},
        @{points=@(@{x=506;y=80},@{x=634;y=80},@{x=754;y=80},@{x=854;y=81},@{x=932;y=100})
          bends=@(@{x=964;y=108},@{x=964;y=204})}
    )
    $best = $null
    $bestDistance = [double]::PositiveInfinity
    foreach ($lane in $lanes) {
        $shoot = $player
        $outbound = [Collections.Generic.List[object]]::new()
        $distance = 0.0
        foreach ($next in @($lane.points) + @($null)) {
            foreach ($ore in $resources) {
                $range = Get-Distance $shoot $ore
                if ($range -lt 32 -or $range -gt $AimRange-1 -or !(Test-OceanSegment $State.room $shoot $ore)) { continue }
                foreach ($bend in @($null) + @($lane.bends)) {
                    $from = if ($bend) { $bend } else { $shoot }
                    if ($bend -and !(Test-OceanSegment $State.room $shoot $bend 18)) { continue }
                    $pickup = Get-StandOffPoint $from $ore (Get-Distance $from $ore) 23
                    $turn = @{x=276;y=268}
                    if ($bend -and $bend.x -eq 156 -and (Get-Distance $turn $ore) -le 25 -and
                        (Test-OceanSegment $State.room $from $turn 18)) { $pickup = $turn }
                    if (!$pickup -or !(Test-OceanSegment $State.room $from $pickup 18)) { continue }
                    $toPickup = if ($bend) { @($bend,$pickup) } else { @($pickup) }
                    $pickupDistance = (Get-Distance $shoot $from) + (Get-Distance $from $pickup)
                    $exit = Get-MagmaIIWestExit $State $shoot $anchor $lane.points
                    if (!$exit) { continue }
                    $total = $distance + 2*$pickupDistance + $exit.distance
                    if ($total -ge $bestDistance -or $player.oxygen -le (Get-MagmaIIReserve $total (1.0/1.8) $ShotFrames)) { continue }
                    $bestDistance = $total
                    $best = @{ore=$ore;shoot=$shoot;outbound=$outbound.ToArray();pickup=$toPickup
                        route=@($lane.points)+$toPickup;roundTrip=$total}
                }
                # The east shaft needs two turns before the last pickup.
                if ($shoot.x -ge 900 -and $lane.bends.Count -eq 2) {
                    $bend1,$bend2 = $lane.bends
                    $pickup = Get-StandOffPoint $bend2 $ore (Get-Distance $bend2 $ore) 23
                    if (!$pickup -or !(Test-OceanSegment $State.room $shoot $bend1 18) -or
                        !(Test-OceanSegment $State.room $bend1 $bend2 18) -or !(Test-OceanSegment $State.room $bend2 $pickup 18)) { continue }
                    $exit = Get-MagmaIIWestExit $State $shoot $anchor $lane.points
                    $travel = (Get-Distance $shoot $bend1)+(Get-Distance $bend1 $bend2)+(Get-Distance $bend2 $pickup)
                    if (!$exit) { continue }
                    $total = $distance + 2*$travel + $exit.distance
                    if ($total -ge $bestDistance -or $player.oxygen -le (Get-MagmaIIReserve $total (1.0/1.8) $ShotFrames)) { continue }
                    $bestDistance = $total
                    $best = @{ore=$ore;shoot=$shoot;outbound=$outbound.ToArray();pickup=@($bend1,$bend2,$pickup)
                        route=@($lane.points)+@($bend1,$bend2,$pickup);roundTrip=$total}
                }
            }
            if (!$next -or !(Test-OceanSegment $State.room $shoot $next 18)) { break }
            $distance += Get-Distance $shoot $next
            $outbound.Add($next)
            $shoot = $next
        }
    }
    return $best
}
function Read-MagmaIIRetreatRefresh($State) {
    $previousPlayerFrame = $State.scene.player.frame
    try {
        return Wait-DiveSnapshot {
            param($sample)
            $sample.scene.player.oxygen -le 0 -or ($sample.scene.player.frame -gt $previousPlayerFrame -and
                $sample.activeInputFrames -eq 0 -and !$sample.flags.transitioning)
        } 'fresh Magma II retreat clearance' -AllowIsland -AllowEmptyOxygen -MaxWaitSeconds 1.1
    } catch {
        if ($_.Exception.Message -ne 'Timed out waiting for fresh Magma II retreat clearance.') { throw }
        return $State
    }
}

function Invoke-MagmaIIWestResource($State) {
    if ($State.room -ne 'rm_ocean_magma_02') { throw 'The Magma II resource route requires its native expedition room.' }
    $route = @{x=400;y=119}, @{x=190;y=119}, @{x=148;y=119}, @{x=148;y=168},
        @{x=143;y=222}, @{x=167;y=234}, @{x=212;y=238}
    $script:magmaReturnPivots = $route
    $script:magmaMinFishClearance = [double]::PositiveInfinity
    $script:magmaPossibleContacts = 0
    $script:magmaPartialRetreats = 0
    $script:magmaMinimumReturnOxygen = $null
    $trail = [Collections.Generic.List[object]]::new()
    $trail.Add($State.scene.player)
    $startingOxygen = [double]$State.scene.player.oxygen
    $minimumOxygen = $startingOxygen
    $minimumReturnOxygen = $null
    $maximumDistance = 0.0
    $framesPerPixel = 1.0 / 1.8
    $startProjectiles = [long]$State.projectiles.plasma
    $shots = 0
    $partialRetreats = 0
    $stepsWithoutProgress = 0
    $pickupAttempted = $false
    $waypoint = 0
    $deadline = [Math]::Min($TimeoutSeconds - 10, $timer.Elapsed.TotalSeconds + $HarvestSeconds)
    $reason = 'magma-ii-harvest-time'
    $terrainAvailable = $nativeTerrain -and $nativeTerrain[$State.room]
    if (!$UseSubmarineBubble -or !$terrainAvailable) {
        $reason = 'magma-ii-bubble-or-terrain-unavailable'
    } else {
        $plan = Get-MagmaIIResourcePlan $State $MagmaPlasmaAimRange $PlasmaHoldFrames
        if (!$plan) { $reason = 'magma-ii-no-safe-collectable-ore' }
        else {
            $route = $plan.route
            $script:magmaReturnPivots = $route
            $previous = $null
            $motion = @()
            $escape = $null
            $closeWaits = 0
            $guardedCrossings = 0
            $firstGuardedCrossing = $null
            $lateralEscapes = 0
            $corridorBypasses = 0
            $lastBlockedMove = $null
            $replannedOre = 0
            $oreBroken = $false
            $ore = $plan.ore
            while ($State.room -eq 'rm_ocean_magma_02' -and $State.scene.player.can_use_tool -eq 1 -and
                   $timer.Elapsed.TotalSeconds -lt $deadline) {
                $player = $State.scene.player
                $anchor = Get-LiveSubmarine $State
                $motion = @(Get-MagmaIIFishMotion $State $previous $motion)
                $previous = $State
                $maximumDistance = [Math]::Max($maximumDistance, (Get-Distance $player $anchor))
                $minimumOxygen = [Math]::Min($minimumOxygen,[double]$player.oxygen)
                $exit = Get-MagmaIIWestExit $State $player $anchor $route
                if (!$exit -or $player.oxygen -le (Get-MagmaIIReserve $exit.distance $framesPerPixel)) {
                    $reason = 'magma-ii-return-reserve'
                    break
                }

                $point = $null
                $chosenEscape = $null
                $liveOre = $State.targets.resources | Where-Object { (Get-Distance $_ $ore) -lt 12 } | Select-Object -First 1
                if ($shots -gt 0 -and !$liveOre -and [long]$State.projectiles.plasma -gt $startProjectiles) {
                    $oreBroken = $true
                }
                $continuingEscape = $escape -and (Get-Distance $player $escape) -gt 14
                if ($continuingEscape) { $point = $escape }
                elseif (!$oreBroken) {
                    if ($shots -ge 4) { $reason = 'magma-ii-plasma-hold-limit'; break }
                    $range = Get-Distance $player $ore
                    $distanceToShot = Get-Distance $player $plan.shoot
                    $nearShot = $distanceToShot -le 42
                    if (!$liveOre -and $distanceToShot -le 18 -and $range -le $MagmaPlasmaAimRange) {
                        $replacement = if ($replannedOre -lt 2 -and $shots -eq 0) {
                            Get-MagmaIIResourcePlan $State $MagmaPlasmaAimRange $PlasmaHoldFrames
                        }
                        if (!$replacement -or (Get-Distance $player $replacement.shoot) -gt 110) {
                            $reason = 'magma-ii-target-missing-at-shooting-range'
                            break
                        }
                        $plan = $replacement
                        $ore = $plan.ore
                        $route = $plan.route
                        $script:magmaReturnPivots = @($route)+$trail.ToArray()
                        $waypoint = 0
                        ++$replannedOre
                        continue
                    }
                    # The bridge only publishes its 24 nearest rocks. A distant target can leave the list mid-route.
                    $ray = $liveOre -and $range -ge 32 -and $range -le $MagmaPlasmaAimRange -and
                        (Test-OceanSegment $State.room $player $liveOre)
                    if ($ray -and $nearShot) {
                        $minimumBurst = $MagmaPlasmaChargeFrames+10
                        $selectedBurst = $null
                        foreach ($burst in ($PlasmaHoldFrames,112,72,$minimumBurst | Sort-Object -Descending -Unique)) {
                            if ($burst -gt $PlasmaHoldFrames -or $burst -lt $minimumBurst -or
                                $player.oxygen -le (Get-MagmaIIReserve $exit.distance $framesPerPixel $burst)) { continue }
                            if (Test-MagmaIIFishHorizon $State $motion $player $player $burst) { $selectedBurst=$burst; break }
                        }
                        if ($selectedBurst) {
                            $State = Invoke-DiveTarget $State $liveOre Resource -PlasmaFrames $selectedBurst
                            ++$shots
                            $minimumOxygen = [Math]::Min($minimumOxygen,[double]$State.scene.player.oxygen)
                            continue
                        }
                    }
                    $inUpperLane = $player.y -ge 30 -and $player.y -le 104
                    $goingWest = $plan.shoot.x -lt $anchor.x
                    while ($waypoint -lt $plan.outbound.Count) {
                        $site = $plan.outbound[$waypoint]
                        if ((Get-Distance $player $site) -le 13) { ++$waypoint; continue }
                        $reachedX = if ($goingWest) { $player.x -le $site.x+12 } else { $player.x -ge $site.x-12 }
                        if ($site.y -gt 101 -or !$inUpperLane -or !$reachedX) { break }
                        ++$waypoint
                        ++$corridorBypasses
                    }
                    if ($waypoint -lt $plan.outbound.Count) {
                        $point = $plan.outbound[$waypoint]
                        if ($inUpperLane -and $point.y -le 101) {
                            $level = @{x=$point.x;y=[Math]::Max(38.0,[double]$player.y)}
                            if (Test-OceanSegment $State.room $player $level 18) { $point = $level }
                        }
                    } elseif ((Get-Distance $player $plan.shoot) -gt 13) { $point = $plan.shoot }
                } else {
                    if (!$pickupAttempted) { $waypoint = 0 }
                    while ($waypoint -lt $plan.pickup.Count -and (Get-Distance $player $plan.pickup[$waypoint]) -le 13) { ++$waypoint }
                    $pickupAttempted = $true
                    if ($waypoint -ge $plan.pickup.Count -or (Get-Distance $player $ore) -le 25) {
                        $reason = 'magma-ii-reached-native-pickup-area'; break
                    }
                    $point = $plan.pickup[$waypoint]
                }
                $escape = $null
                $clearance = Get-MagmaNearestFishDistance $State $player
                if ($point) {
                    $distanceToPoint = Get-Distance $player $point
                    $pulseSpeed = if ($continuingEscape) { 2.0 } else { 3.5 }
                    $frames = if ($continuingEscape -and $distanceToPoint -gt 35) {
                        [int][Math]::Clamp([Math]::Ceiling($distanceToPoint/$pulseSpeed),10.0,92.0)
                    } elseif ($clearance -lt 172) { 8 } elseif ($distanceToPoint -gt 70) { 24 } else { 13 }
                    $forecast = Get-MagmaIISwimEndpoint $player $point $frames $pulseSpeed
                    $geometryClear = Test-OceanSegment $State.room $player $forecast 12
                    $safe = if ($geometryClear) { Test-MagmaIIFishHorizon $State $motion $player $forecast $frames }
                    if (!$safe -and $geometryClear -and @($motion | Where-Object { $null -ne $_.earliestBlast }).Count -gt 0) {
                        $turns = @($point,$exit.point)
                        $dx = $forecast.x-$player.x
                        $dy = $forecast.y-$player.y
                        if ([Math]::Abs($dx) -ge 14 -and [Math]::Abs($dx) -gt 2*[Math]::Abs($dy)) {
                            foreach ($span in 78,108,132) {
                                $turns += @{x=$forecast.x+[Math]::Sign($dx)*$span;y=$forecast.y}
                            }
                        }
                        foreach ($candidate in $turns) {
                            $extension = Get-Distance $forecast $candidate
                            if ($extension -gt 135 -or !(Test-OceanSegment $State.room $forecast $candidate 16)) { continue }
                            $afterExit = Get-MagmaIIWestExit $State $candidate $anchor $route
                            if (!$afterExit -or $player.oxygen -le (Get-MagmaIIReserve ($extension+$afterExit.distance) $framesPerPixel)) { continue }
                            if ([Math]::Abs($candidate.y-$player.y) -lt 4 -and
                                [Math]::Sign($candidate.x-$player.x) -eq [Math]::Sign($dx)) {
                                $directDistance = Get-Distance $player $candidate
                                # The first live straight pulse gained 87.4 px in about 42 applied Steps.
                                $crossSpeed = 2.0
                                $directFrames = [int][Math]::Clamp([Math]::Ceiling($directDistance/$crossSpeed),8.0,92.0)
                                $directEnd = Get-MagmaIISwimEndpoint $player $candidate $directFrames $crossSpeed
                                if (Test-OceanSegment $State.room $player $directEnd 18) {
                                    $direct = Test-MagmaIIFishHorizon $State $motion $player $directEnd $directFrames $candidate
                                    if ($direct -and $direct.timed) {
                                        $safe=$direct
                                        $point=$candidate
                                        $forecast=$directEnd
                                        $distanceToPoint=$directDistance
                                        $frames=$directFrames
                                        $pulseSpeed=$crossSpeed
                                        $chosenEscape=$candidate
                                        break
                                    }
                                }
                            }
                            $safe = Test-MagmaIIFishHorizon $State $motion $player $forecast $frames $candidate
                            if ($safe) { $chosenEscape=$candidate; break }
                        }
                    }
                    if (!$safe -and $clearance -lt 172 -and $distanceToPoint -gt 40) {
                        foreach ($burst in 16,22) {
                            $lateralEnd = Get-MagmaIISwimEndpoint $player $point $burst $pulseSpeed
                            if (!(Test-OceanSegment $State.room $player $lateralEnd 18)) { continue }
                            $safe = Test-MagmaIIFishHorizon $State $motion $player $lateralEnd $burst
                            if ($safe) { $frames=$burst; break }
                        }
                    }
                    $bypassIndex = $null
                    if (!$safe -and !$oreBroken -and $waypoint + 1 -lt $plan.outbound.Count) {
                        $bypass = $plan.outbound[$waypoint + 1]
                        $bypassDistance = Get-Distance $player $bypass
                        if ($bypassDistance -lt $distanceToPoint + 44 -and
                            (Test-OceanSegment $State.room $player $bypass 18) -and
                            (Get-MagmaIIWestExit $State $bypass $anchor $route)) {
                            foreach ($burst in 14,18) {
                                $bypassEnd = Get-MagmaIISwimEndpoint $player $bypass $burst $pulseSpeed
                                if (!(Test-OceanSegment $State.room $player $bypassEnd 12)) { continue }
                                $safe = Test-MagmaIIFishHorizon $State $motion $player $bypassEnd $burst
                                if ($safe) {
                                    $point = $bypass
                                    $distanceToPoint = $bypassDistance
                                    $frames = $burst
                                    $bypassIndex = $waypoint + 1
                                    break
                                }
                            }
                        }
                    }
                    if (!$safe) {
                        $lastBlockedMove = @{
                            frame=$State.frame;from=@{x=$player.x;y=$player.y};point=$point;forecast=$forecast
                            terrainClear=$geometryClear;fishClearance=$clearance
                            fuseTracks=@($motion | Where-Object { $null -ne $_.earliestBlast }).Count
                            nearest=@($motion | Sort-Object playerDistance | Select-Object -First 3)
                        }
                    }
                    if ($safe) {
                        if ($safe.timed) {
                            ++$guardedCrossings
                            $escape = $chosenEscape
                            if (!$firstGuardedCrossing) {
                                $firstGuardedCrossing = @{frame=$State.frame;from=@{x=$player.x;y=$player.y};forecast=$forecast
                                    exit=$escape;predictedHazards=$safe.timed;fishClearance=$clearance
                                    nativeDeadline=$safe.deadline;requestedFrames=$frames}
                            }
                        } elseif ($continuingEscape) { $escape = $point }
                        $State = Swim-Pulse $State $point $frames $pulseSpeed -TrackFrames
                        if ($firstGuardedCrossing -and !$firstGuardedCrossing.arrivalFrame -and
                            ($safe.timed -or $continuingEscape)) {
                            $firstGuardedCrossing.afterFrame = $State.frame
                            $firstGuardedCrossing.after = @{x=$State.scene.player.x;y=$State.scene.player.y}
                            $firstGuardedCrossing.appliedFrames = $State.swimPulseFrames
                            $firstGuardedCrossing.remainingToExit = Get-Distance $State.scene.player $firstGuardedCrossing.exit
                            $firstGuardedCrossing.afterClearance = Get-MagmaNearestFishDistance $State $State.scene.player
                            $firstGuardedCrossing.afterOxygen = $State.scene.player.oxygen
                            if ($firstGuardedCrossing.remainingToExit -le 18 -and
                                $firstGuardedCrossing.afterClearance -ge 126 -and $State.scene.player.can_use_tool -eq 1) {
                                $firstGuardedCrossing.arrivalFrame = $State.frame
                                $firstGuardedCrossing.arrivedBeforeDeadline = $State.frame -lt $firstGuardedCrossing.nativeDeadline
                            }
                        }
                        $trail.Add($State.scene.player)
                        $minimumOxygen = [Math]::Min($minimumOxygen,[double]$State.scene.player.oxygen)
                        $progress = $distanceToPoint - (Get-Distance $State.scene.player $point)
                        if ($null -ne $bypassIndex -and $progress -gt 3) {
                            $waypoint = $bypassIndex
                            ++$corridorBypasses
                        }
                        $stepsWithoutProgress = if ($progress -ge .5) { 0 } else { $stepsWithoutProgress+1 }
                        $closeWaits = 0
                        if ($stepsWithoutProgress -ge 3) { $reason = 'magma-ii-scout-stalled'; break }
                        continue
                    }
                }
                $reserveAfterWait = Get-MagmaIIReserve $exit.distance $framesPerPixel 45
                $risingBank = $lastBlockedMove.terrainClear -and @($motion | Where-Object {
                    $_.tracked -and $_.playerDistance -lt 220 -and $_.vy -lt -.22
                }).Count -gt 0
                $waitLimit = if ($risingBank -and $player.oxygen -ge $reserveAfterWait+150000) { 11 } else { 3 }
                $safeToWait = Test-MagmaIIFishHorizon $State $motion $player $player 34
                if (!$safeToWait -and $clearance -lt 230 -and $closeWaits -lt $waitLimit -and
                    $player.oxygen -gt $reserveAfterWait) {
                    $duringDodge = if ($point) { $point } else { $exit.point }
                    $dodge = Get-MagmaIILateralStep $State $motion $duringDodge
                    if ($dodge) {
                        $State = Swim-Pulse $State $dodge 6 2.5 -TrackFrames
                        $trail.Add($State.scene.player)
                        ++$lateralEscapes
                        ++$closeWaits
                        continue
                    }
                }
                if (!$safeToWait -or ++$closeWaits -gt $waitLimit -or $player.oxygen -le $reserveAfterWait) {
                    $reason = 'magma-ii-scout-or-pickup-blocked'
                    break
                }
                $State = Read-MagmaIIRetreatRefresh $State
            }
        }
    }
    $projectiles = [long]$State.projectiles.plasma - $startProjectiles
    $stepsWithoutProgress = 0
    while ($terrainAvailable -and $State.room -eq 'rm_ocean_magma_02' -and $State.scene.player.oxygen -gt 0) {
        $State = Wait-MagmaDiverReadyForReturn $State
        if ($State.room -ne 'rm_ocean_magma_02') { break }
        $player = $State.scene.player
        $anchor = Get-LiveSubmarine $State
        $minimumReturnOxygen = if ($null -eq $minimumReturnOxygen) { $player.oxygen }
            else { [Math]::Min($minimumReturnOxygen, [double]$player.oxygen) }
        if ((Get-Distance $player $anchor) -le 43) { break }

        $step = Get-MagmaIIReturnStep $State $anchor $route
        if ($step) {
            $next = Swim-Pulse $State $step.point 6 3.0 -Returning
            if ($next.room -ne 'rm_ocean_magma_02' -or $next.scene.player.oxygen -le 0) {
                $State = $next
                break
            }
            $progress = (Get-Distance $player $step.point) - (Get-Distance $next.scene.player $step.point)
            $stepsWithoutProgress = if ($progress -ge 0.5) { 0 } else { $stepsWithoutProgress + 1 }
            if ($step.clearance -eq 60) { ++$partialRetreats }
        } else {
            ++$stepsWithoutProgress
            $next = Read-MagmaIIRetreatRefresh $State
        }
        $State = $next
        if ($stepsWithoutProgress -ge 6) {
            # Continue with native breadcrumb and local escape recovery before the pressure reserve drains.
            $retreatFallback = $true
            break
        }
    }
    $beforeReturn = $State.scene.player.oxygen
    $returned = Return-ToIsland $State $trail
    if ($returned.room -eq 'rm_main_island') { [IO.File]::Delete($returnCheckpoint) }
    $returned | Add-Member -NotePropertyName autoplayDive -NotePropertyValue ([pscustomobject]@{
        magmaIIWestResource=$true; reason=$reason; shots=$shots
        plasmaProjectiles=$projectiles; attemptedPickup=$pickupAttempted; partialRetreats=$partialRetreats
        plannedOre=$plan.ore;plannedRoundTrip=$plan.roundTrip;retreatFallback=[bool]$retreatFallback;replannedOre=$replannedOre;guardedCrossings=$guardedCrossings;firstGuardedCrossing=$firstGuardedCrossing;lateralEscapes=$lateralEscapes;corridorBypasses=$corridorBypasses;lastBlockedMove=$lastBlockedMove
        startingOxygen=$startingOxygen; minimumHarvestOxygen=$minimumOxygen; minimumReturnOxygen=$minimumReturnOxygen
        oxygenBeforeReturn=$beforeReturn; oxygenAfterReturn=$returned.scene.player.oxygen
        maxDistanceFromSubmarine=[Math]::Round($maximumDistance, 1)
        elapsedMs=$timer.ElapsedMilliseconds
    })
    return $returned
}


function Get-MagmaIIFishMotion($State, $Previous, $Past) {
    $elapsed = if ($Previous -and $Previous.pid -eq $State.pid -and $Previous.room -eq $State.room) {
        [long]$State.frame - [long]$Previous.frame
    } else { 0 }
    if ($Previous -and $elapsed -eq 0 -and $State.frame -eq $Previous.frame -and $Past) { return $Past }
    $buildUp = if ($MagmaShockFrequency) { 440L } else { 170L }
    $roomEarliest = if ($MagmaBeforeEntryFrame -gt 0 -and $State.frame -ge $MagmaBeforeEntryFrame -and
        $State.frame -lt $MagmaBeforeEntryFrame + $buildUp) { $MagmaBeforeEntryFrame + $buildUp }
    $used = [Collections.Generic.HashSet[int]]::new()
    foreach ($fish in $State.targets.jellyfish) {
        if ($null -eq $fish.x -or $null -eq $fish.y) { continue }
        $vx = $vy = 0.0
        $tracked = $false
        $distance = Get-Distance $fish $State.scene.player
        $outside = if ($distance -gt 244) { [long]$State.frame }
        # A newly entered room has no warning state left over from the previous expedition.
        $earliest = $roomEarliest
        if ($elapsed -ge 1 -and $elapsed -le 90) {
            $match = -1
            $verticalMatch = -1
            $verticalMatches = 0
            $best = $second = [double]::PositiveInfinity
            for ($i = 0; $i -lt $Past.Count; ++$i) {
                if ($used.Contains($i)) { continue }
                $gap = Get-Distance $fish $Past[$i]
                if ($gap -le 3.0*$elapsed -and [Math]::Abs($fish.x-$Past[$i].x) -le .025) {
                    $verticalMatch = $i
                    ++$verticalMatches
                }
                if ($gap -lt $best) { $second=$best; $best=$gap; $match=$i }
                elseif ($gap -lt $second) { $second=$gap }
            }
            if ($verticalMatches -eq 1) {
                $match = $verticalMatch
            } elseif ($match -lt 0 -or $best -gt 3.0*$elapsed -or $second-$best -lt 12) {
                $match = -1
            }
            if ($match -ge 0) {
                $old = $Past[$match]
                $null = $used.Add($match)
                if ($elapsed -ge 10) {
                    $tracked = $true
                    $vx = ($fish.x-$old.x)/$elapsed
                    $vy = ($fish.y-$old.y)/$elapsed
                } else {
                    # Adjacent observations preserve identity and the fuse, but give a noisy velocity.
                    $tracked = $old.tracked
                    $vx = $old.vx
                    $vy = $old.vy
                }
                $oldColumnGap = [double]$Previous.scene.player.x-$old.x
                $newColumnGap = [double]$State.scene.player.x-$fish.x
                # Untouched Magma fish rise vertically. Allow slack for residual diver motion at either sample.
                $stableColumn = $verticalMatches -eq 1 -and $Previous.scene.player.can_use_tool -eq 1 -and
                    $State.scene.player.can_use_tool -eq 1 -and $State.projectiles.bubble -eq $Previous.projectiles.bubble -and
                    $State.projectiles.plasma -eq $Previous.projectiles.plasma -and $oldColumnGap*$newColumnGap -gt 0 -and
                    [Math]::Min([Math]::Abs($oldColumnGap),[Math]::Abs($newColumnGap)) -gt 270
                if ($stableColumn -or [Math]::Min($distance,$old.playerDistance) - 4.0*$elapsed -gt 244) {
                    $outside = if ($null -ne $old.outsideSince) { $old.outsideSince } else { [long]$Previous.frame }
                } elseif ($null -ne $old.outsideSince -and $Previous.frame-$old.outsideSince -ge 190) {
                    $trigger = [long]$Previous.frame + [long][Math]::Max(0.0,[Math]::Floor(($old.playerDistance-244)/8))
                    # Count from the earliest possible proximity, with slack for the pre-warning delay.
                    $earliest = [Math]::Max([long]$roomEarliest,$trigger+$buildUp)
                } elseif ($null -ne $old.earliestBlast -and $old.earliestBlast -gt $State.frame) {
                    $earliest = [Math]::Max([long]$roomEarliest,[long]$old.earliestBlast)
                }
            }
        }
        [pscustomobject]@{x=[double]$fish.x;y=[double]$fish.y;vx=$vx;vy=$vy;tracked=$tracked
            playerDistance=$distance;outsideSince=$outside;earliestBlast=$earliest}
    }
}

function Get-MagmaIIFishClearance($Fish, $From, $To, [int]$Start, [int]$End) {
    $x = $Fish.x+$Fish.vx*$Start-$From.x
    $y = $Fish.y+$Fish.vy*$Start-$From.y
    $dx = $Fish.vx*($End-$Start)-($To.x-$From.x)
    $dy = $Fish.vy*($End-$Start)-($To.y-$From.y)
    $squared = $dx*$dx+$dy*$dy
    $t = if ($squared -gt .001) { [Math]::Clamp(-($x*$dx+$y*$dy)/$squared,0.0,1.0) } else { 0.0 }
    return [Math]::Sqrt([Math]::Pow($x+$t*$dx,2)+[Math]::Pow($y+$t*$dy,2))
}

function Test-MagmaIIFishHorizon($State, $Tracks, $From, $To, [int]$Frames, $Exit) {
    $duration = $Frames+15
    $safeAt = if ($Exit) { $duration + 15 + [int][Math]::Ceiling((Get-Distance $To $Exit)/1.8) }
    $timed = 0
    $deadline = [long]::MaxValue
    foreach ($fish in $Tracks) {
        $extra = if ($fish.tracked) { 0.0 } else { 10.0 }
        $body = 49.0 + $extra
        $blast = 126.0 + $extra
        $start = Get-Distance $From $fish
        $closest = Get-MagmaIIFishClearance $fish $From $To 0 $duration
        $finish = Get-MagmaIIFishClearance $fish $To $To $duration $duration
        $exitClosest = $finish
        if ($Exit) {
            $exitClosest = Get-MagmaIIFishClearance $fish $To $Exit $duration $safeAt
            $finish = Get-MagmaIIFishClearance $fish $Exit $Exit $safeAt $safeAt
        }
        if ($closest -lt [Math]::Min($body,$start)-.05 -or
            ($Exit -and $exitClosest -lt [Math]::Min($body,$closest)-.05)) { return }
        if ([Math]::Min($closest,$exitClosest) -ge $blast) { continue }
        if ($Exit -and $null -ne $fish.earliestBlast -and [long]$State.frame+$safeAt+16 -lt $fish.earliestBlast -and
            $finish -ge $blast+12) {
            ++$timed
            $deadline = [Math]::Min($deadline,[long]$fish.earliestBlast)
            continue
        }
        if ($start -ge $blast -or $finish -lt $start+7) { return }
        if ([Math]::Min($closest,$exitClosest) -ge $start-.05) { continue }
        if ($Exit -or $closest -lt $body) { return }

        # A rising fish can briefly close distance even during a lateral escape.
        # The straight pulse must improve separation over staying still for the whole interval.
        $dx = $To.x-$From.x
        $dy = $To.y-$From.y
        $initialGain = ($From.x-$fish.x)*$dx + ($From.y-$fish.y)*$dy
        $ifStationary = Get-MagmaIIFishClearance $fish $From $From $duration $duration
        if ($initialGain -lt 0 -or $finish -lt $ifStationary+8) { return }
    }
    return @{timed=$timed;deadline=if ($timed) {$deadline}}
}

function Get-MagmaIISwimEndpoint($From, $Point, [int]$Frames, [double]$PixelsPerFrame = 2.5) {
    $dx = $Point.x-$From.x
    $dy = $Point.y-$From.y
    $major = [Math]::Max([Math]::Abs($dx),[Math]::Abs($dy))
    $threshold = [Math]::Max(3.0,.32*$major)
    $Frames = [int][Math]::Clamp([Math]::Floor(($major-6)/$PixelsPerFrame),6.0,[double]$Frames)
    return @{
        x=$From.x + $(if ([Math]::Abs($dx) -gt $threshold) { [Math]::Sign($dx)*$Frames*$PixelsPerFrame } else { 0 })
        y=$From.y + $(if ([Math]::Abs($dy) -gt $threshold) { [Math]::Sign($dy)*$Frames*$PixelsPerFrame } else { 0 })
    }
}
function Get-MagmaIILateralStep($State, $Tracks, $Toward) {
    $player = $State.scene.player
    $best = $null
    $rating = [double]::NegativeInfinity
    foreach ($heading in @(@{x=-1;y=0},@{x=1;y=0},@{x=0;y=1},@{x=0;y=-1})) {
        $point = @{x=$player.x+18*$heading.x;y=$player.y+18*$heading.y}
        $forecast = Get-MagmaIISwimEndpoint $player $point 6
        if (!(Test-OceanSegment $State.room $player $forecast 12) -or
            !(Test-MagmaIIFishHorizon $State $Tracks $player $forecast 6)) { continue }
        $distance = Get-MagmaNearestFishDistance $State $forecast
        $score = $distance - .25*(Get-Distance $forecast $Toward)
        if ($score -gt $rating) { $rating=$score; $best=$point }
    }
    return $best
}
function Get-MagmaIIShelterSites($Center) {
    $Center
    foreach ($offset in @(@{x=-54;y=0},@{x=38;y=-8},@{x=62;y=-3},@{x=-37;y=-36},@{x=36;y=-37},@{x=0;y=42},@{x=-89;y=37},@{x=89;y=37})) {
        @{x=$Center.x + $offset.x;y=$Center.y + $offset.y}
    }
}

function Get-MagmaIIFishAngle($State, $Position, $Tracks) {
    $best = $null
    $score = [double]::NegativeInfinity
    foreach ($fish in $Tracks) {
        $distance = Get-Distance $Position $fish
        if ($distance -lt 70 -or $distance -gt 260) { continue }
        $lead = if ($fish.tracked) { [Math]::Clamp(($distance - 32) / 8.0, 5.0, 24.0) } else { 0.0 }
        $aim = @{x=$fish.x + $fish.vx*$lead;y=$fish.y + $fish.vy*$lead}
        if (!(Test-OceanSegment $State.room $Position $aim)) { continue }
        $rating = 260.0 - [Math]::Abs($distance - 116.0)
        if ($rating -gt $score) {
            $score = $rating
            $best = @{target=$aim;distance=$distance;rating=$rating}
        }
    }
    return $best
}

function Invoke-MagmaIIShelterFishing($State) {
    $script:magmaMinFishClearance = [double]::PositiveInfinity
    $script:magmaPossibleContacts = 0
    $script:magmaPartialRetreats = 0
    $script:magmaMinimumReturnOxygen = $null
    $startOxygen = [double]$State.scene.player.oxygen
    $minimum = $startOxygen
    $startShots = [long]$State.projectiles.bubble
    $previous = $null
    $motion = @()
    $escape = $null
    $timedActions = 0
    $fuseTracks = 0
    $shots = 0
    $moves = 0
    $tracked = 0
    $reason = 'magma-ii-fishing-budget'
    $deadline = [Math]::Min($TimeoutSeconds - 8, $timer.Elapsed.TotalSeconds + $HarvestSeconds)
    $openWater = @{x=400;y=119},@{x=365;y=117},@{x=524;y=116},@{x=574;y=163},@{x=620;y=118}
    $script:magmaReturnPivots = $openWater
    while ($State.room -eq $diveRoom -and $State.scene.player.can_use_tool -eq 1 -and
        $State.scene.player.oxygen -gt 0 -and $timer.Elapsed.TotalSeconds -lt $deadline) {
        $anchor = Get-LiveSubmarine $State
        $center = @{x=$anchor.x-6;y=$anchor.y-24}
        $player = $State.scene.player
        $inside = (Get-Distance $player $center) -le 90
        $minimum = [Math]::Min($minimum,[double]$player.oxygen)
        $closest = Get-MagmaNearestFishDistance $State $player
        $script:magmaMinFishClearance = [Math]::Min($script:magmaMinFishClearance, $closest)
        $motion = @(Get-MagmaIIFishMotion $State $previous $motion)
        $tracked = [Math]::Max($tracked, @($motion | Where-Object tracked).Count)
        $previous = $State
        $fuseTracks = [Math]::Max($fuseTracks,@($motion | Where-Object { $null -ne $_.earliestBlast }).Count)
        $pack = $State.inventories.player
        if ($pack.slotCount -gt 0 -and $pack.slotCapacity -gt 0 -and $pack.total -ge $pack.slotCount * $pack.slotCapacity) {
            $reason = 'magma-ii-fishing-backpack-full'
            break
        }
        $travel = Get-Distance $player $anchor
        if (!$inside -and $player.oxygen -le (Get-MagmaIIReserve $travel (1.0/1.8) 22)) {
            $reason = 'magma-ii-fishing-return-oxygen'
            break
        }
        $sites = @(Get-MagmaIIShelterSites $center)
        if ($closest -gt 170 -and $player.oxygen -gt $startOxygen*.75) {
            $sites += @(@{x=$center.x-90;y=$center.y},@{x=$center.x+108;y=$center.y})
        }
        $hasWindow = $fuseTracks -gt 0 -and @($motion | Where-Object { $null -ne $_.earliestBlast }).Count -gt 0
        $exits = if ($hasWindow) {
            @($sites | Where-Object { (Get-Distance $_ $center) -lt 100 -and
                (Get-Distance $_ $player) -le 125 -and (Test-OceanSegment $State.room $_ $anchor 12) } |
                Sort-Object { Get-MagmaNearestFishDistance $State $_ } -Descending | Select-Object -First 4)
        }
        $action = $null
        if ($escape -and (Get-Distance $player $escape) -ge 15) {
            $next = Get-MagmaIISwimEndpoint $player $escape 8
            if ((Test-OceanSegment $State.room $player $next 10) -and
                (Test-MagmaIIFishHorizon $State $motion $player $next 8 $escape)) {
                $action = @{point=$escape;frames=8;exit=$escape}
            }
        }
        $escape = $null
        if (!$action) {
            $aim = Get-MagmaIIFishAngle $State $player $motion
            if ($aim) {
                $burst = if ($closest -ge 175) { 30 } else { 16 }
                $plan = Test-MagmaIIFishHorizon $State $motion $player $player ($burst+8)
                $exit = $null
                if (!$plan) {
                    foreach ($candidate in $exits) {
                        if (!(Test-OceanSegment $State.room $player $candidate 12)) { continue }
                        $plan = Test-MagmaIIFishHorizon $State $motion $player $player ($burst+8) $candidate
                        if ($plan) { $exit=$candidate; break }
                    }
                }
                if ($plan) { $action = @{aim=$aim.target;frames=$burst;exit=$exit;timed=$plan.timed} }
            }
        }
        if (!$action) {
            $best = [double]::NegativeInfinity
            foreach ($point in $sites) {
                $length = Get-Distance $player $point
                if ($length -lt 15 -or !(Test-OceanSegment $State.room $player $point 12) -or
                    !(Test-OceanSegment $State.room $point $anchor 12)) { continue }
                $frames = [int][Math]::Clamp([Math]::Floor(($length-8.0)/3.0),6.0,14.0)
                $next = Get-MagmaIISwimEndpoint $player $point $frames
                if (!(Test-OceanSegment $State.room $player $next 12)) { continue }
                $plan = Test-MagmaIIFishHorizon $State $motion $player $next $frames
                $exit = $null
                if (!$plan) {
                    foreach ($candidate in $exits) {
                        if (!(Test-OceanSegment $State.room $next $candidate 12)) { continue }
                        $plan = Test-MagmaIIFishHorizon $State $motion $player $next $frames $candidate
                        if ($plan) { $exit=$candidate; break }
                    }
                }
                if (!$plan) { continue }
                $pointAim = Get-MagmaIIFishAngle $State $point $motion
                $score = if ($pointAim) { $pointAim.rating-.5*$length } else { 135-.5*$length-(Get-Distance $point $center) }
                if ($score -gt $best) {
                    $best = $score
                    $action = @{point=$point;frames=$frames;exit=$exit;timed=$plan.timed}
                }
            }
        }
        if ($action) {
            if ($action.timed) { ++$timedActions }
            $escape = $action.exit
            if ($action.aim) {
                $State = Invoke-DiveTarget $State $action.aim Jellyfish -BubbleFrames $action.frames
                ++$shots
            } else {
                $State = Swim-Pulse $State $action.point $action.frames 2.5 -TrackFrames
                ++$moves
            }
            $minimum = [Math]::Min($minimum,[double]$State.scene.player.oxygen)
            if ($State.scene.player.can_use_tool -eq 0 -and $player.oxygen-$State.scene.player.oxygen -ge $magmaContactDrop) {
                ++$script:magmaPossibleContacts
            }
            continue
        }
        if (!$inside) { $reason = 'magma-ii-fishing-outside-clear-angle'; break }
        $new = Read-MagmaIIRetreatRefresh $State
        if ($new.frame -le $State.frame) { $reason = 'magma-ii-fishing-old-telemetry'; break }
        $State = $new
    }
    $caughtProjectiles = [long]$State.projectiles.bubble - $startShots
    $beforeReturn = $State.scene.player.oxygen
    $returned = Return-ToIsland $State @($openWater)
    $returned | Add-Member -NotePropertyName autoplayDive -NotePropertyValue ([pscustomobject]@{
        magmaIIShelterFishing=$true;reason=$reason;shots=$shots;moves=$moves
        bubbleProjectiles=$caughtProjectiles;trackedFish=$tracked;fuseTracks=$fuseTracks;timedActions=$timedActions;startingOxygen=$startOxygen
        minimumHarvestOxygen=$minimum;oxygenBeforeReturn=$beforeReturn;minimumReturnOxygen=$script:magmaMinimumReturnOxygen
        possibleContacts=$script:magmaPossibleContacts;elapsedMs=$timer.ElapsedMilliseconds
    })
    return $returned
}
