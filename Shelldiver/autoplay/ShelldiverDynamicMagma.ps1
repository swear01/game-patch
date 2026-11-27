# Dot-source after the native terrain, motion and control helpers.
function Initialize-DynamicMagmaRoute {
    if (!('ShelldiverDynamicRoute' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ShelldiverDynamicRoute.cs')
    }
}

function Get-DynamicMagmaContactDamage([double]$BaseDamage) {
    # The original player hit path uses the same native shock resistance for Magma species.
    $resistance = if ($MagmaShockResistance) { 1.5 } else { 0.0 }
    if ($MagmaShockResistanceII) { $resistance += 999.9 }
    return $BaseDamage / (1.0 + $resistance)
}

function Get-DynamicMagmaHazards($State, $Tracks, [switch]$AllowBlastExposure) {
    $deep = $State.room -eq 'rm_ocean_magma_03'
    $frame = [long]$State.frame
    $blastCost = switch ($State.room) {
        'rm_ocean_magma_03' { (Get-DynamicMagmaContactDamage 200000) * 30.0 / 25000 }
        'rm_ocean_magma_01' { (Get-DynamicMagmaContactDamage 20000) * 30.0 / 4000 }
        default { 69.0 }
    }
    foreach ($fish in $Tracks) {
        $hazard = [ShelldiverDynamicRoute+Hazard]::new()
        $hazard.X = $fish.x
        $hazard.Y = $fish.y
        $hazard.Vx = $fish.vx
        $hazard.Vy = $fish.vy
        $hazard.BodyRadius = if ($fish.tracked) { 51 } else { 62 }
        $hazard.BlastRadius = if ($deep) { if ($fish.tracked) { 156 } else { 167 } }
            elseif ($fish.tracked) { 126 } else { 137 }
        if ($AllowBlastExposure) { $hazard.BlastCostSteps = $blastCost }
        $hazard.BlastNotBefore = if ($fish.earliestBlast) { [int][Math]::Max(0L,[long]$fish.earliestBlast-$Frame-18L) } else { 0 }
        $hazard
    }
}

function Find-DynamicMagmaPath($State, $From, $Destination, $Hazards, [int]$Nodes = 1400, [switch]$NearWallRecovery,
                               [int]$MinimumMargin = 6) {
    $map = $nativeTerrain[$State.room]
    if (!$map) { return }
    if ($State.room -eq 'rm_ocean_magma_03' -and !$Hazards) { $Nodes = [Math]::Max($Nodes,4000) }
    $margins=if ($Hazards -and !$NearWallRecovery) { 16,11 } else { 16,11,6 }
    foreach ($margin in $margins) {
        if ($margin -lt $MinimumMargin) { continue }
        if (!(Test-OceanSegment $State.room $From $From $margin) -or
            !(Test-OceanSegment $State.room $Destination $Destination $margin)) { continue }
        $route=[ShelldiverDynamicRoute]::Find($map.rows,$map.tileWidth,$map.tileHeight,$From.x,$From.y,
            $Destination.x,$Destination.y,$margin,2.0,$Nodes,[ShelldiverDynamicRoute+Hazard[]]$Hazards)
        if ($route.Length) { return $route }
    }
}

function Get-DynamicPathLength($From, $Route) {
    $distance = 0.0
    foreach ($point in $Route) {
        $distance += Get-Distance $From $point
        $From = $point
    }
    return $distance
}

function Get-DynamicMagmaReserve($State, [double]$Distance, [int]$ActionSteps = 0) {
    $returnSteps = [Math]::Ceiling($Distance/1.55)+48+$ActionSteps
    if ($State.room -eq 'rm_ocean_magma_03') {
        # Red blast and body contact share the original oxygen damage. Reserve two hits.
        $contact = Get-DynamicMagmaContactDamage 200000
        return 25000*[Math]::Ceiling($returnSteps/30)+2*$contact
    }
    if ($State.room -eq 'rm_ocean_magma_01') {
        return 4000*[Math]::Ceiling($returnSteps/30)+2*(Get-DynamicMagmaContactDamage 20000)
    }
    return 7000*[Math]::Ceiling($returnSteps/30)+32000
}

function Test-DynamicMagmaAction($State, $Tracks, $Position, [int]$Frames) {
    if ($State.room -eq 'rm_ocean_magma_02') {
        return Test-MagmaIIFishHorizon $State $Tracks $Position $Position $Frames
    }
    $duration = $Frames+15
    foreach ($hazard in (Get-DynamicMagmaHazards $State $Tracks)) {
        if ((Get-MagmaIIFishClearance $hazard $Position $Position 0 $duration) -lt $hazard.BodyRadius) { return $false }
        if ($hazard.BlastNotBefore -le $duration -and
            (Get-MagmaIIFishClearance $hazard $Position $Position $hazard.BlastNotBefore $duration) -lt $hazard.BlastRadius) {
            return $false
        }
    }
    return $true
}

function Get-DynamicMagmaFishAim($State, $Position, $Tracks) {
    if ($State.room -ne 'rm_ocean_magma_03') { return Get-MagmaIIFishAngle $State $Position $Tracks }
    $ranked=@($Tracks | Sort-Object { [Math]::Abs((Get-Distance $Position $_)-175) })
    $fallback=foreach ($fish in $ranked) {
        $aim=Get-MagmaIIFishAngle $State $Position @($fish)
        if ($aim) { $aim; break }
    }
    $hitLimit=[int][Math]::Floor($MagmaBubblePenetration)
    if (!$fallback -or $hitLimit -lt 2 -or $ranked.Count -lt 2) { return $fallback }

    # Native bubbles lose 2% velocity per step and can hit multiple unique fish.
    # Keep the established 260px targeting limit and score only center-line hits.
    $speed=[double]$MagmaBubbleProjectileSpeed
    $flight=[int]$MagmaBubbleProjectileLifetime
    $range=[Math]::Min(260.0,32.0+$speed*(1-[Math]::Pow(.98,$flight))/.02)
    $damping=[Math]::Log(.98)
    $points=@(foreach ($fish in $ranked) {
        $distance=Get-Distance $Position $fish
        if ($distance -lt 36 -or $distance -gt $range+24) { continue }
        $travel=[Math]::Max(0.0,$distance-32.0)
        $ratio=[Math]::Min(.99,$travel*.02/$speed)
        $lead=if ($fish.tracked) { [Math]::Min(28.0,[Math]::Log(1.0-$ratio)/$damping) } else { 0.0 }
        $point=@{x=$fish.x+$lead*$fish.vx;y=$fish.y+$lead*$fish.vy}
        if ((Get-Distance $Position $point) -le $range -and (Test-OceanSegment $State.room $point $point)) { $point }
    })
    $winner=$fallback
    $bestCount=1
    foreach ($candidate in ($points | Select-Object -First 8)) {
        $length=Get-Distance $Position $candidate
        if ($length -lt 70 -or !(Test-OceanSegment $State.room $Position $candidate)) { continue }
        $dx=($candidate.x-$Position.x)/$length
        $dy=($candidate.y-$Position.y)/$length
        $count=0
        foreach ($fish in $points) {
            $fx=$fish.x-$Position.x
            $fy=$fish.y-$Position.y
            $along=$fx*$dx+$fy*$dy
            # 10px lies inside the stock Red body mask even without bubble-size bonuses.
            if ($along -lt 34 -or $along -gt $range -or [Math]::Abs($fx*$dy-$fy*$dx) -gt 10) { continue }
            $contact=@{x=$Position.x+$along*$dx;y=$Position.y+$along*$dy}
            if (!(Test-OceanSegment $State.room $Position $contact)) { continue }
            if (++$count -ge $hitLimit) { break }
        }
        if ($count -gt $bestCount) {
            $bestCount=$count
            $winner=@{target=$candidate;distance=$length;schoolTargets=$count}
            if ($bestCount -ge $hitLimit) { break }
        }
    }
    return $winner
}

function Update-DynamicMagmaFishFocus($State, $Focus) {
    $current = @{}
    foreach ($fish in $State.targets.jellyfish) {
        if (!$fish.track -or $null -eq $fish.observedFrame -or $null -eq $fish.life -or
            !$fish.lifeMax -or $null -eq $fish.x -or $null -eq $fish.y) { continue }
        $id = [string]$fish.track
        $age = [long]$State.frame - [long]$fish.observedFrame
        if ($age -lt 0 -or $age -gt 30) { continue }
        $item = @{
            track=$id; x=[double]$fish.x; y=[double]$fish.y; observedFrame=[long]$fish.observedFrame
            life=[double]$fish.life; lifeMax=[double]$fish.lifeMax; vx=0.0; vy=0.0
            invulnerable=[bool]($fish.invulnerable -or $fish.explosion)
        }
        $old = $Focus.current[$id]
        $elapsed = if ($old) { $item.observedFrame - $old.observedFrame } else { 0 }
        if ($old -and $elapsed -ge 0 -and $elapsed -le 90) {
            $item.vx=$old.vx
            $item.vy=$old.vy
            if ($elapsed -ge 4) {
                $item.vx = [Math]::Clamp(($item.x-$old.x)/$elapsed,-3.5,3.5)
                $item.vy = [Math]::Clamp(($item.y-$old.y)/$elapsed,-3.5,3.5)
            }
            if ($elapsed -gt 0 -and $old.life -gt 0 -and $item.life -lt $old.life) {
                $decrease = $old.life - [Math]::Max(0.0,$item.life)
                ++$Focus.healthDrops
                $Focus.healthLost += $decrease
                if ($item.life -le 0) { ++$Focus.finishes }
                if ($Focus.locked -eq $id) {
                    ++$Focus.focusedDrops
                    $Focus.noProgressShots = 0
                    $Focus.awaitSince = $null
                    # Use repeated nonlethal losses. Opening/execute strikes can remove much more.
                    if ($item.life -gt 0 -and $old.life -lt $old.lifeMax) {
                        $Focus.lossEstimate = if ($Focus.lossEstimate) {
                            [Math]::Min($Focus.lossEstimate,$decrease)
                        } else { $decrease }
                    }
                }
            }
            if ($elapsed -gt 0 -and $item.life -gt $old.life -and $Focus.locked -eq $id) {
                ++$Focus.resets
                $Focus.skip = $id
                $Focus.skipUntil = $State.frame + 100
                $Focus.locked = $null
            }
        }
        if ($Focus.locked -eq $id -and $item.invulnerable) {
            if (!$old -or !$old.invulnerable) { ++$Focus.invulnerableWindows }
            $Focus.awaitSince = $null
            $Focus.noProgressShots = 0
        }
        $current[$id] = $item
    }
    if ($Focus.locked -and (!$current.ContainsKey($Focus.locked) -or $current[$Focus.locked].life -le 0)) {
        # Out of the nearest-24 telemetry, wrapped or gone. Absence alone is no finish.
        ++$Focus.releases
        $Focus.locked = $null
    }
    if (!$Focus.locked) {
        $Focus.awaitSince = $null
        $Focus.noProgressShots = 0
    }
    if ($Focus.locked -and $null -ne $Focus.awaitSince -and $Focus.noProgressShots -ge 12 -and
        $State.frame -ge $Focus.awaitSince + $Focus.waitFrames) {
        ++$Focus.missedWindows
        $Focus.skip = $Focus.locked
        $Focus.skipUntil = $State.frame + 100
        $Focus.locked = $null
        $Focus.awaitSince = $null
        $Focus.noProgressShots = 0
    }
    $Focus.current = $current
}

function Get-DynamicMagmaLockedFishAim($State, $Position, $Focus) {
    $speed=[double]$MagmaBubbleProjectileSpeed
    $lifetime=[int]$MagmaBubbleProjectileLifetime
    $decay=.98
    $timeConstant=[Math]::Log($decay)
    $maxRange=[Math]::Min(260.0,32.0+$speed*(1-[Math]::Pow($decay,$lifetime))/(1-$decay))
    $best=$null
    foreach ($fish in $Focus.current.Values) {
        if ($fish.life -le 0 -or $fish.invulnerable -or $fish.y -lt 10 -or
            ($fish.track -eq $Focus.skip -and $State.frame -lt $Focus.skipUntil)) { continue }
        $distance=Get-Distance $Position $fish
        if ($distance -lt 64 -or $distance -gt $maxRange+22) { continue }
        $age=$State.frame-$fish.observedFrame
        $flight=0.0
        for ($step=0; $step -lt 3; ++$step) {
            $lead=$age+6+$flight
            $point=@{x=$fish.x+$fish.vx*$lead;y=$fish.y+$fish.vy*$lead}
            $length=Get-Distance $Position $point
            $travel=[Math]::Max(0.0,$length-32.0)
            $ratio=[Math]::Min(.99,$travel*(1-$decay)/$speed)
            $flight=[Math]::Log(1.0-$ratio)/$timeConstant
        }
        if ($flight -gt $lifetime -or $length -lt 62 -or $length -gt $maxRange -or $point.y -lt 8 -or
            !(Test-OceanSegment $State.room $Position $point)) { continue }

        # Actual observed losses incorporate Smite, First Strike and native executes.
        # Before a repeatable loss sample, score by remaining HP on the normal Red scale.
        $damage = if ($Focus.lossEstimate) { $Focus.lossEstimate } else { 16000.0 }
        $intervals=[Math]::Ceiling($fish.life/$damage)
        $score=$flight+8*$intervals+[Math]::Abs($length-125)/12.0
        if ($fish.vy -lt -.2 -and ($point.y/(-$fish.vy)) -lt (8*$intervals)) { $score+=45 }
        $option=@{target=$point;distance=$length;schoolTargets=1;track=$fish.track;flight=[int][Math]::Ceiling($flight);score=$score}
        if ($fish.track -eq $Focus.locked) { return $option }
        if (!$best -or $option.score -lt $best.score) { $best=$option }
    }
    return $best
}

function Get-DynamicMagmaLeg($State, $Tracks, $Goal, [switch]$AllowBlastExposure, [switch]$NearWallRecovery) {
    $player = $State.scene.player
    $hazards = @(Get-DynamicMagmaHazards $State $Tracks -AllowBlastExposure:$AllowBlastExposure)
    $localGoal = $Goal
    $distance = Get-Distance $player $Goal
    if ($distance -gt 116) {
        $terrainOnly = @(Find-DynamicMagmaPath $State $player $Goal $null)
        if (!$terrainOnly.Count) { return }
        $localGoal = $terrainOnly[0]
        $width = Get-Distance $player $localGoal
        if ($width -gt 102) {
            $localGoal = @{x=$player.x+102*($localGoal.x-$player.x)/$width;y=$player.y+102*($localGoal.y-$player.y)/$width}
        }
    }
    $path = @(Find-DynamicMagmaPath $State $player $localGoal $hazards 1100 -NearWallRecovery:$NearWallRecovery)
    $next = $path | Where-Object { (Get-Distance $player $_) -ge 5 } | Select-Object -First 1
    if (!$next) { return }
    return @{point=$next;path=$path;exposure=[bool]$AllowBlastExposure}
}

function Get-DynamicMagmaChase($State, $Tracks, $Anchor, [double]$Oxygen) {
    $player = $State.scene.player
    $goals = [Collections.Generic.List[object]]::new()
    $deep = $State.room -eq 'rm_ocean_magma_03'
    $lastY = if ($deep) { $nativeTerrain[$State.room].rows.Length*$nativeTerrain[$State.room].tileHeight } else { 620 }
    $reach = if ($deep) { 900 } else { 625 }
    $standOff = if ($deep) { 175 } else { 108 }
    $firstSafeY = if ($deep) { 78 } else { 24 }
    $promising = @($Tracks | Where-Object { $_.y -ge 32 -and $_.y -le $lastY -and $_.playerDistance -lt $reach } |
        Sort-Object playerDistance | Select-Object -First 6)
    foreach ($fish in $promising) {
        $leadY = $fish.y + 16*[Math]::Clamp([double]$fish.vy,-2.2,1.0)
        foreach ($angle in 0,45,90,135,180,225,270,315) {
            $radians=$angle*[Math]::PI/180
            $point=@{x=$fish.x+$standOff*[Math]::Cos($radians);y=$leadY+$standOff*[Math]::Sin($radians)}
            if ($point.y -lt $firstSafeY -or !(Test-OceanSegment $State.room $point $point 15) -or
                !(Test-OceanSegment $State.room $point @{x=$fish.x;y=$leadY})) { continue }
            $gap=Get-Distance $player $point
            $backToSubDistance=Get-Distance $point $Anchor
            if ($gap -lt 13 -or $Oxygen -le (Get-DynamicMagmaReserve $State ($gap+$backToSubDistance) 40)) { continue }
            $goals.Add(@{point=$point;cost=$gap+.27*$backToSubDistance})
        }
    }

    $shortlist = foreach ($candidate in ($goals | Sort-Object cost | Select-Object -First 9)) {
        $returnPath=@(Find-DynamicMagmaPath $State $candidate.point $Anchor $null 4000)
        if (!$returnPath.Count -and (Get-Distance $candidate.point $Anchor) -gt 20) { continue }
        $pathHome=Get-DynamicPathLength $candidate.point $returnPath
        $outbound=@(Find-DynamicMagmaPath $State $player $candidate.point $null 3400)
        if (!$outbound.Count) { continue }
        $travel=Get-DynamicPathLength $player $outbound
        if ($Oxygen -le (Get-DynamicMagmaReserve $State ($travel+$pathHome) 55)) { continue }
        @{point=$candidate.point;outbound=$travel;back=$pathHome;cost=$travel+.23*$pathHome}
    }
    $shortlist=@($shortlist | Sort-Object cost | Select-Object -First 6)
    foreach ($candidate in $shortlist) {
        $leg=Get-DynamicMagmaLeg $State $Tracks $candidate.point
        if ($leg) { return $leg }
    }
    foreach ($candidate in ($shortlist | Select-Object -First 4)) {
        if ($Oxygen -le (Get-DynamicMagmaReserve $State ($candidate.outbound+$candidate.back) 90)) { continue }
        $leg=Get-DynamicMagmaLeg $State $Tracks $candidate.point -AllowBlastExposure
        if ($leg) { return $leg }
    }
}

function Get-DynamicMagmaScout($State, $Tracks, $Anchor) {
    $player=$State.scene.player
    $deep=$State.room -eq 'rm_ocean_magma_03'
    $lastY=if ($deep) { $nativeTerrain[$State.room].rows.Length*$nativeTerrain[$State.room].tileHeight } else { 680 }
    foreach ($fish in ($Tracks | Where-Object { $_.y -gt 45 -and $_.y -lt $lastY -and $_.playerDistance -gt 132 } |
        Sort-Object playerDistance | Select-Object -First 5)) {
        $angle=[Math]::Atan2($fish.y-$player.y,$fish.x-$player.x)
        $stride=[Math]::Min(112.0,$fish.playerDistance-80)
        foreach ($rotation in 0.0,.5,-.5) {
            $heading=$angle+$rotation
            $point=@{x=$player.x+$stride*[Math]::Cos($heading);y=$player.y+$stride*[Math]::Sin($heading)}
            if (($deep -and $point.y -lt 78) -or !(Test-OceanSegment $State.room $point $point 15)) { continue }
            $back=@(Find-DynamicMagmaPath $State $point $Anchor $null 1700)
            if (!$back.Count -and (Get-Distance $point $Anchor) -gt 22) { continue }
            $trip=$stride+(Get-DynamicPathLength $point $back)
            if ($player.oxygen -le (Get-DynamicMagmaReserve $State $trip 145)) { continue }
            $leg=Get-DynamicMagmaLeg $State $Tracks $point -AllowBlastExposure
            if ($leg) { return $leg }
        }
    }
}
function Get-DynamicMagmaAirGoal($State, $Anchor) {
    if ($State.room -in 'rm_ocean_magma_01','rm_ocean_magma_03' -and !$UseSubmarineBubble) { return $Anchor }
    $player=$State.scene.player
    $center=@{x=$Anchor.x-6;y=$Anchor.y-24}
    if ((Get-Distance $player $center) -le 94) { return $Anchor }
    $startAngle=[Math]::Atan2($player.y-$center.y,$player.x-$center.x)
    $best=$null
    $smallest=[double]::PositiveInfinity
    foreach ($offset in 0,.524,-.524,1.047,-1.047,1.571,-1.571,3.142) {
        $a=$startAngle+$offset
        $goal=@{x=$center.x+87*[Math]::Cos($a);y=$center.y+87*[Math]::Sin($a)}
        if (!(Test-OceanSegment $State.room $goal $goal 10)) { continue }
        $route=@(Find-DynamicMagmaPath $State $player $goal $null 4200)
        if (!$route.Count) { continue }
        $distance=Get-DynamicPathLength $player $route
        if ($distance -lt $smallest) { $best=$goal; $smallest=$distance }
    }
    if ($best) { return $best }
    return $Anchor
}
function Test-DynamicMagmaAir($Player, $Anchor) {
    if (!$UseSubmarineBubble) { return $false }
    # Stock bubble center is hatch(-6,-24), with a 100px effective radius.
    $center=@{x=$Anchor.x-6;y=$Anchor.y-24}
    return (Get-Distance $Player $center) -le 88
}

function Get-DynamicMagmaRescueLeg($State, $Tracks, $Destination, $Trail, $Avoid, [switch]$PermitContact) {
    $player=$State.scene.player
    $route=@(Find-DynamicMagmaPath $State $player $Destination $null 4200)
    $forward=$route | Where-Object { (Get-Distance $player $_) -ge 6 } | Select-Object -First 1
    $pivot=if ($forward) { $forward } else { $Destination }
    $heading=[Math]::Atan2($pivot.y-$player.y,$pivot.x-$player.x)
    $candidates=[Collections.Generic.List[object]]::new()
    if ($forward) {
        $distance=Get-Distance $player $forward
        $factor=[Math]::Min(1.0,64/$distance)
        $candidates.Add(@{x=$player.x+$factor*($forward.x-$player.x);y=$player.y+$factor*($forward.y-$player.y)})
    }
    $recorded=0
    for ($i=$Trail.Count-1;$i -ge 0 -and $recorded -lt 4;--$i) {
        $distance=Get-Distance $player $Trail[$i]
        if ($distance -lt 14 -or $distance -gt 90) { continue }
        if (!(Test-OceanSegment $State.room $player $Trail[$i] 6)) { continue }
        $candidates.Add($Trail[$i])
        ++$recorded
    }
    foreach ($offset in 0,.785,-.785,1.571,-1.571,2.356,-2.356,3.142) {
        $angle=$heading+$offset
        foreach ($length in 28,52) {
            $candidates.Add(@{x=$player.x+$length*[Math]::Cos($angle);y=$player.y+$length*[Math]::Sin($angle)})
        }
    }

    $startClear=Test-OceanSegment $State.room $player $player 6
    $best=$null
    $bestScore=[double]::PositiveInfinity
    foreach ($point in $candidates) {
        $length=Get-Distance $player $point
        if ($length -lt 5 -or ($Avoid | Where-Object { (Get-Distance $point $_) -lt 13 } | Select-Object -First 1)) { continue }
        if (!(Test-OceanSegment $State.room $player $point 6)) {
            if ($startClear -or !(Test-OceanSegment $State.room $player $point) -or
                !(Test-OceanSegment $State.room $point $point 11)) { continue }
        }
        $duration=[int][Math]::Clamp([Math]::Ceiling($length/2.0),8,32)
        $bodyRisk=0.0
        foreach($fish in $Tracks) {
            $clearance=Get-MagmaIIFishClearance $fish $player $point 0 $duration
            if ($clearance -ge 62) { continue }
            $fromFish=Get-Distance $player $fish
            if ($clearance+1 -ge $fromFish -and (Get-Distance $point $fish) -gt $fromFish+8) { continue }
            $bodyRisk+=62-$clearance
        }
        if ($bodyRisk -gt 0 -and !$PermitContact) { continue }
        $path=@(Find-DynamicMagmaPath $State $point $Destination $null 4200)
        if (!$path.Count -and (Get-Distance $point $Destination) -gt 10) { continue }
        $score=(Get-DynamicPathLength $point $path)+.45*$length+4*$bodyRisk
        if ($score -lt $bestScore) {
            $best=@{point=$point;exposure=$bodyRisk -gt 0}
            $bestScore=$score
        }
    }
    return $best
}

function Swim-DynamicMagmaHome($State, [double]$TargetDistance, $Trail, [switch]$ToAir) {
    $previous=$null
    $motion=@()
    $stalls=0
    $avoided=[Collections.Generic.List[object]]::new()
    $deep=$State.room -eq 'rm_ocean_magma_03'
    while ($State.room -eq $diveRoom -and $State.scene.player.can_use_tool -eq 1 -and $State.scene.player.oxygen -gt 0) {
        if ($deep -and $State.flags.pause) { throw [OperationCanceledException]::new('The native Shelldiver dive is paused.') }
        $anchor=Get-LiveSubmarine $State
        $player=$State.scene.player
        $distance=Get-Distance $player $anchor
        if ($ToAir -and (Test-DynamicMagmaAir $player $anchor)) { return $State }
        if (!$deep -or !$ToAir -or !$UseSubmarineBubble) {
            if ($distance -le $TargetDistance -or ($deep -and $anchor.can_be_used -and $anchor.range -ge 40 -and
                $distance -le $anchor.range-24)) { return $State }
        }
        $motion=@(Get-MagmaIIFishMotion $State $previous $motion)
        $previous=$State
        $exit=if ($deep -and !$ToAir) { $anchor } else { Get-DynamicMagmaAirGoal $State $anchor }
        $nearWall=$State.room -in 'rm_ocean_magma_01','rm_ocean_magma_03' -and !(Test-OceanSegment $State.room $player $player 11)
        $leg=$null
        if (!$deep -or !$stalls) {
            $leg=Get-DynamicMagmaLeg $State $motion $exit -NearWallRecovery:$nearWall
            if (!$leg) { $leg=Get-DynamicMagmaLeg $State $motion $exit -AllowBlastExposure -NearWallRecovery:$nearWall }
        }
        $rescue=$false
        if ($deep -and !$leg) {
            $leg=Get-DynamicMagmaRescueLeg $State $motion $exit $Trail $avoided -PermitContact:$MagmaShockResistanceII
            $rescue=$null -ne $leg
        }
        if ($leg) {
            $frames=if ($rescue) { if ($nearWall) { 14 } else { 26 } } else { 38 }
            $next=Swim-Pulse $State $leg.point $frames 2.0 -Returning -TrackFrames -AnalogHeading
            Add-MagmaReturnObservation $next $State
            if ($next.room -ne $diveRoom -or $next.scene.player.can_use_tool -ne 1) { return $next }
            $moved=(Get-Distance $player $leg.point)-(Get-Distance $next.scene.player $leg.point)
            if ($moved -ge $(if ($deep) { 2 } else { .5 })) { $stalls=0; $avoided.Clear(); $State=$next; continue }
            if ($deep) { $avoided.Add($leg.point) }
            $State=$next
        } else {
            $State=Read-MagmaIIRetreatRefresh $State
        }
        if (++$stalls -ge $(if ($deep) { 7 } else { 4 })) { break }
    }
    if ($deep) {
        if ($State.room -ne $diveRoom -or $State.scene.player.can_use_tool -ne 1 -or $State.scene.player.oxygen -le 0) { return $State }
        $player=$State.scene.player
        Write-Verbose "1200m return blocked at ($([Math]::Round($player.x,1)), $([Math]::Round($player.y,1))) with $($player.oxygen) oxygen."
        # The session retries from fresh native telemetry before handling a terminal failure.
        throw 'No safe dynamic Magma return step was available.'
    }
    return Swim-MagmaSafeReturn $State $TargetDistance $Trail
}

function Close-DynamicMagmaInventory($State) {
    $previous=$null
    $motion=@()
    for ($attempt=0;$attempt -lt 8;++$attempt) {
        if ($State.room -ne $diveRoom -or !$State.flags.player_inventory_open -or
            $State.scene.player.oxygen -le 0) { return $State }
        $motion=@(Get-MagmaIIFishMotion $State $previous $motion)
        $previous=$State
        $anchor=Get-LiveSubmarine $State
        $player=$State.scene.player
        $leg=if ((Get-Distance $player $anchor) -gt 28) {
            Get-DynamicMagmaLeg $State $motion (Get-DynamicMagmaAirGoal $State $anchor) -AllowBlastExposure
        }
        if ($leg) {
            $State=Swim-Pulse $State $leg.point 15 2.0 -Returning -TrackFrames -CloseInventory -AnalogHeading
        } else {
            $State=Invoke-DiveCommand $State input @{frames=4;values=@{open_inventory=$true}} 4 -AllowIsland -ResultStage
        }
    }
    return $State
}

function Wait-DynamicMagmaHitSnapshot($State) {
    $sceneFrame=[long]$State.scene.player.frame
    $wasReady=$State.scene.player.can_use_tool -eq 1
    try {
        return Wait-DiveSnapshot {
            param($sample)
            $sample.flags.pause -or $sample.scene.player.oxygen -le 0 -or
                ($sample.activeInputFrames -eq 0 -and !$sample.flags.transitioning -and
                    ($sample.scene.player.frame -ge $sceneFrame+10 -or
                        (!$wasReady -and $sample.scene.player.can_use_tool -eq 1 -and $sample.scene.player.frame -gt $sceneFrame)))
        } 'native 1200m hit recovery to advance' -AllowIsland -AllowEmptyOxygen -MaxWaitSeconds 1.1
    } catch {
        if ($_.Exception.Message -ne 'Timed out waiting for native 1200m hit recovery to advance.') { throw }
        return $State
    }
}

function Wait-DynamicMagmaAfterHit($State) {
    $previous=$null
    $motion=@()
    $deep=$State.room -eq 'rm_ocean_magma_03'
    $limit=if ($deep) { 12 } else { 9 }
    for ($attempt=0;$attempt -lt $limit;++$attempt) {
        if ($State.room -ne $diveRoom -or $State.scene.player.can_use_tool -eq 1 -or
            $State.scene.player.oxygen -le 0) { return $State }
        if ($deep -and $State.flags.pause) { throw 'The native 1200m diver is paused during hit recovery.' }
        $anchor=Get-LiveSubmarine $State
        $player=$State.scene.player
        $motion=@(Get-MagmaIIFishMotion $State $previous $motion)
        $previous=$State
        $leg=if (!$State.flags.transitioning -and (Get-Distance $player $anchor) -gt 30) {
            $nearWall=$deep -and !(Test-OceanSegment $State.room $player $player 11)
            Get-DynamicMagmaLeg $State $motion (Get-DynamicMagmaAirGoal $State $anchor) -AllowBlastExposure -NearWallRecovery:$nearWall
        }
        if ($leg) {
            $State=Swim-Pulse $State $leg.point 13 2.0 -Returning -TrackFrames -AnalogHeading
        } elseif ($deep) {
            $State=Wait-DynamicMagmaHitSnapshot $State
        } else {
            $State=Read-MagmaIIRetreatRefresh $State
        }
    }
    if ($deep -and ($State.room -ne $diveRoom -or $State.scene.player.can_use_tool -eq 1 -or
        $State.scene.player.oxygen -le 0)) { return $State }
    throw 'The dynamic Magma diver did not regain control before docking.'
}
function Test-DynamicMagmaBadgeFull($State) {
    if (!$Mailbox -or !$script:dynamicMagmaEntryFrame -or !$State.pid) { return $false }
    $now=[DateTime]::UtcNow
    if (!$script:dynamicMagmaNextBadgeRead -or $now -ge $script:dynamicMagmaNextBadgeRead) {
        $script:dynamicMagmaNextBadgeRead=$now.AddMilliseconds(350)
        try {
            $script:dynamicMagmaBadge=[IO.File]::ReadAllText((Join-Path $Mailbox 'catch-badge.json')) | ConvertFrom-Json
        } catch {
            $script:dynamicMagmaBadge=$null
        }
    }
    $badge=$script:dynamicMagmaBadge
    # The native badge count tracks new items, so only its explicit FULL signal is authoritative.
    return $badge.pid -eq $State.pid -and $badge.room -eq $State.room -and
        $badge.lastFullFrame -gt $script:dynamicMagmaEntryFrame -and $badge.lastFullFrame -le $State.frame -and
        $badge.observedFrame -ge $badge.lastFullFrame
}

function Test-DynamicMagmaPackFull($State, [bool]$RecentlyFired) {
    $pack=$State.inventories.player
    return ($State.scene.player.is_inventory_full -eq $true) -or ($State.scene.player.inventory_full -eq $true) -or
        ($pack.slotCount -gt 0 -and $pack.slotCapacity -gt 0 -and $pack.total -ge $pack.slotCount*$pack.slotCapacity) -or
        ($State.room -ne 'rm_ocean_magma_03' -and $RecentlyFired -and $State.flags.player_inventory_open -eq $true -and !$State.flags.pause) -or
        (Test-DynamicMagmaBadgeFull $State)
}

function Wait-DynamicMagmaBubbleSupply($State, [int]$Frames, [switch]$Magazine) {
    $until=[long]$State.frame+$Frames
    try {
        return Wait-DiveSnapshot {
            param($sample)
            if ($sample.flags.player_inventory_open -or $sample.flags.pause -or $sample.scene.player.can_use_tool -ne 1) { return $true }
            if ($Magazine) {
                return $sample.scene.bubbleGun.current_ammo_number -gt 0 -or $sample.frame -ge $until
            }
            $reserve = $sample.scene.player.bubbles
            if ($null -eq $reserve) { $reserve = $sample.scene.player.bubble_ammo }
            $clip = if ($sample.scene.bubbleGun.total_ammo_number -gt 0) { $sample.scene.bubbleGun.total_ammo_number } else { 27 }
            if ($sample.scene.player.bubbles_max -gt 0) { $clip = [Math]::Min($clip,$sample.scene.player.bubbles_max) }
            # After air activates, Bubble II supplies 5% of tank capacity per 15-step tick.
            $reserve -ge $clip -or $sample.frame -ge $until
        } 'the native bubble weapon to replenish ammo' -AllowIsland -MaxWaitSeconds 8
    } catch {
        if ($_.Exception.Message -ne 'Timed out waiting for the native bubble weapon to replenish ammo.') { throw }
        return Read-DiveSnapshot
    }
}

function Invoke-DynamicMagmaBubbleReload($State) {
    return Invoke-DiveCommand $State input @{frames=1;values=@{reload_tool=1}} 1
}

function Invoke-DynamicMagmaRefill($State, $Trail, [switch]$ReloadBubble, [switch]$WaitForBubble) {
    $destination=Swim-DynamicMagmaHome $State 27 $Trail
    if ($destination.room -ne $diveRoom -or $destination.scene.player.oxygen -le 0) { return $destination }
    if ($ReloadBubble -and $destination.scene.player.can_use_tool -eq 1 -and
        !$destination.flags.player_inventory_open -and !$destination.flags.pause) {
        if ($WaitForBubble -and $UseSubmarineAmmoBubble) {
            $destination=Wait-DynamicMagmaBubbleSupply $destination 96
        }
        if ($destination.room -ne $diveRoom -or $destination.scene.player.can_use_tool -ne 1 -or
            $destination.flags.player_inventory_open -or $destination.flags.pause) { return $destination }
        $destination=Invoke-DynamicMagmaBubbleReload $destination
        if ($WaitForBubble) { $destination=Wait-DynamicMagmaBubbleSupply $destination 120 -Magazine }
        if ($destination.room -ne $diveRoom -or $destination.scene.player.can_use_tool -ne 1 -or
            $destination.flags.player_inventory_open -or $destination.flags.pause) { return $destination }
    }
    $before=$destination.scene.player
    if ($before.oxygen -ge .92*$before.oxygen_max) { return $destination }
    return Wait-DiveSnapshot {
        param($sample)
        $sample.flags.player_inventory_open -or $sample.scene.player.oxygen -ge .92*$sample.scene.player.oxygen_max
    } 'the original submarine air to refill the tank' -AllowIsland -MaxWaitSeconds 8
}
function Get-DynamicMagmaFishingEdgeEscape($State, $Tracks, $Anchor) {
    $player = $State.scene.player
    $nearCeiling = $player.y -lt 62
    $inward = if ($nearCeiling) { [Math]::PI/2.0 }
        else { [Math]::Atan2($Anchor.y-$player.y,$Anchor.x-$player.x) }
    $candidates = foreach ($offset in 0.0,.55,-.55,1.05,-1.05,1.57,-1.57) {
        $direction = $inward + $offset
        $point = @{x=$player.x+74*[Math]::Cos($direction);y=$player.y+74*[Math]::Sin($direction)}
        if ($point.y -ge 78 -and (Test-OceanSegment $State.room $point $point 16)) { $point }
    }
    foreach ($expose in $false,$true) {
        foreach ($point in $candidates) {
            if ($expose) {
                $pathToSub = @(Find-DynamicMagmaPath $State $point $Anchor $null)
                if (!$pathToSub.Count -and (Get-Distance $point $Anchor) -gt 25) { continue }
                $distance = (Get-Distance $player $point)+(Get-DynamicPathLength $point $pathToSub)
                if ($player.oxygen -le (Get-DynamicMagmaReserve $State $distance 18)) { continue }
            }
            $leg = Get-DynamicMagmaLeg $State $Tracks $point -NearWallRecovery -AllowBlastExposure:$expose
            if ($leg -and (!$nearCeiling -or $leg.point.y -gt $player.y+2)) { return $leg }
        }
    }
}

function Get-DynamicMagmaHuntLeg($State, $Tracks, $Anchor, $Trail, $Hunt, [switch]$Edge) {
    $player=$State.scene.player
    $map=$nativeTerrain[$State.room]
    $lastY=$map.rows.Length*$map.tileHeight-48
    $avoid=@($Hunt.blocked | Where-Object { $_.until -gt $State.frame })
    $goals=[Collections.Generic.List[object]]::new()
    foreach ($fish in ($Tracks | Where-Object { $_.y -ge 64 -and $_.y -le $lastY } |
        Sort-Object { Get-Distance $player $_ } | Select-Object -First 3)) {
        $y=$fish.y+16*[Math]::Clamp([double]$fish.vy,-2.2,1.0)
        $heading=[Math]::Atan2($player.y-$y,$player.x-$fish.x)
        foreach ($rotation in .72,-.72,1.4,-1.4) {
            $angle=$heading+$rotation
            $point=@{x=$fish.x+170*[Math]::Cos($angle);y=$y+170*[Math]::Sin($angle)}
            if (Test-OceanSegment $State.room $point @{x=$fish.x;y=$y}) { $goals.Add(@{point=$point;kind='angle'}) }
        }
    }
    $heading=if ($player.y -lt 78) { [Math]::PI/2 } elseif ($player.y -gt $lastY-110) { -[Math]::PI/2 }
        elseif ($player.x -lt $map.width/2) { 0.0 } else { [Math]::PI }
    foreach ($rotation in 0,.785,-.785,1.57,-1.57,2.356,-2.356,3.142) {
        $angle=$heading+$rotation
        foreach ($length in 62,114) {
            $point=@{x=$player.x+$length*[Math]::Cos($angle);y=$player.y+$length*[Math]::Sin($angle)}
            $goals.Add(@{point=$point;kind='search'})
        }
    }

    $ranked=foreach ($candidate in $goals) {
        $point=$candidate.point
        $distance=Get-Distance $player $point
        if ($point.y -lt 78 -or $point.y -gt $lastY -or $distance -lt 30 -or $distance -gt 230 -or
            !(Test-OceanSegment $State.room $point $point 11) -or
            ($avoid | Where-Object { (Get-Distance $point $_) -lt 22 } | Select-Object -First 1)) { continue }
        $repeat=if ($Hunt.visited | Where-Object { (Get-Distance $point $_) -lt 48 } | Select-Object -First 1) { 90 } else { 0 }
        $priority=if ($candidate.kind -eq 'angle') { 0 } else { 32 }
        @{point=$point;kind=$candidate.kind;score=$distance+$repeat+$priority}
    }
    $nearWall=!(Test-OceanSegment $State.room $player $player 11)
    foreach ($candidate in ($ranked | Sort-Object score | Select-Object -First 10)) {
        $goal=$candidate.point
        $back=@(Find-DynamicMagmaPath $State $goal $Anchor $null 3400 -MinimumMargin 11)
        if (!$back.Count -and (Get-Distance $goal $Anchor) -gt 24) { continue }
        $out=@(Find-DynamicMagmaPath $State $player $goal $null 3400)
        if (!$out.Count -and !$nearWall) { continue }
        $outDistance=if ($out.Count) { Get-DynamicPathLength $player $out } else { (Get-Distance $player $goal)+70 }
        $trip=$outDistance+(Get-DynamicPathLength $goal $back)
        if ($player.oxygen -le (Get-DynamicMagmaReserve $State $trip 110)) { continue }
        $leg=Get-DynamicMagmaLeg $State $Tracks $goal -NearWallRecovery:$nearWall
        if (!$leg -and $MagmaShockResistanceII) { $leg=Get-DynamicMagmaLeg $State $Tracks $goal -AllowBlastExposure -NearWallRecovery:$nearWall }
        if ($leg -and ($avoid | Where-Object { (Get-Distance $leg.point $_) -lt 18 } | Select-Object -First 1)) { $leg=$null }
        if (!$leg -and ($Edge -or $Hunt.noProgress -ge 2)) {
            $leg=Get-DynamicMagmaRescueLeg $State $Tracks $goal $Trail $avoid -PermitContact:$MagmaShockResistanceII
        }
        if (!$leg -or ($player.y -lt 62 -and $leg.point.y -le $player.y+3)) { continue }
        if ($nearWall -and !(Find-DynamicMagmaPath $State $leg.point $Anchor $null 4200) -and
            (Get-Distance $leg.point $Anchor) -gt 24) { continue }
        return @{point=$leg.point;goal=$goal;exposure=$leg.exposure;hunt=$candidate.kind}
    }
}

function Add-DynamicMagmaHuntObservation($Hunt, $State, $Next, $Leg) {
    $player=$State.scene.player
    $observed=$Next.scene.player
    $advance=(Get-Distance $player $Leg.point)-(Get-Distance $observed $Leg.point)
    $displacement=Get-Distance $player $observed
    $Hunt.last=@{kind=$Leg.hunt;x=$player.x;y=$player.y;targetX=$Leg.point.x;targetY=$Leg.point.y;
        frame=$State.frame;afterFrame=$Next.frame;advance=[Math]::Round($advance,1);movement=[Math]::Round($displacement,1)}
    if ($advance -ge 2.0) {
        if (!$Hunt.visited.Count -or (Get-Distance $Hunt.visited[$Hunt.visited.Count-1] $observed) -gt 27) {
            $Hunt.visited.Add(@{x=$observed.x;y=$observed.y})
            if ($Hunt.visited.Count -gt 10) { $Hunt.visited.RemoveAt(0) }
        }
        $Hunt.noProgress=0
        return $true
    }
    if ($Next.room -eq $State.room -and $Next.scene.player.can_use_tool -eq 1 -and $Next.frame -gt $State.frame) {
        $Hunt.blocked.Add(@{x=$Leg.point.x;y=$Leg.point.y;until=([long]$Next.frame+420)})
        if ($Hunt.blocked.Count -gt 14) { $Hunt.blocked.RemoveAt(0) }
        ++$Hunt.failedPulses
    }
    ++$Hunt.noProgress
    return $false
}

function Stop-DynamicMagmaBlockedHunt($State, $Hunt, [string]$Stage) {
    $player=$State.scene.player
    $detail=if ($Hunt.last) { " Last pulse moved $($Hunt.last.movement)px at frame $($Hunt.last.afterFrame)." } else { '' }
    throw "1200m native fishing $Stage blocked at ($([Math]::Round($player.x,1)), $([Math]::Round($player.y,1))) with $($player.oxygen) oxygen. $($Hunt.failedPulses) blocked pulses, $($Hunt.noRoute) no-route observations.$detail"
}

function Get-DynamicMagmaShotEgress($State, $Tracks) {
    if ($State.room -ne $diveRoom -or $State.scene.player.can_use_tool -ne 1 -or
        $State.scene.player.oxygen -le 0 -or $State.flags.pause -or $State.flags.transitioning -or
        $State.flags.player_inventory_open -or (Test-DynamicMagmaPackFull $State $true)) { return }

    $player = $State.scene.player
    if (Test-DynamicMagmaAction $State $Tracks $player 16) { return }
    $anchor = Get-LiveSubmarine $State
    # The shot has ended. Replan a short move against the current sweep
    # instead of trusting an escape computed before the fish moved.
    return Get-DynamicMagmaLeg $State $Tracks (Get-DynamicMagmaAirGoal $State $anchor)
}

function Invoke-DynamicMagmaFishing($State) {
    $script:magmaMinFishClearance=[double]::PositiveInfinity
    $script:magmaPossibleContacts=0
    $script:magmaPartialRetreats=0
    $script:magmaMinimumReturnOxygen=$null
    $trail=[Collections.Generic.List[object]]::new()
    $previous=$null
    $motion=@()
    $shots=0
    $moves=0
    $exposed=0
    $replans=0
    $stalls=0
    $minimum=[double]$State.scene.player.oxygen
    $deep=$State.room -eq 'rm_ocean_magma_03'
    $starting=$minimum
    $script:dynamicMagmaEntryFrame=if ($MagmaBeforeEntryFrame -gt 0 -and $MagmaBeforeEntryFrame -lt $State.frame) {
        $MagmaBeforeEntryFrame
    } else { $State.frame }
    $script:dynamicMagmaBadge=$null
    $script:dynamicMagmaNextBadgeRead=$null
    $startShots=[long]$State.projectiles.bubble
    $farthest=0.0
    $reason='dynamic-fishing-time'
    $refills=0
    $evasiveMoves=0
    $schoolBursts=0
    $edgeMoves=0
    $edgeStalls=0
    $hunt=@{visited=[Collections.Generic.List[object]]::new();blocked=[Collections.Generic.List[object]]::new();
        noProgress=0;failedPulses=0;noRoute=0;repositionMoves=0;last=$null}
    $activeDeepHunt=$deep -and $FillBackpack
    $bubbleReloads=0
    $dryBursts=0
    $dryBurstsTotal=0
    $dryReloadAttempts=0
    $shotsAtLastReload=0
    $lastShotFrame=-10000L
    $fishFocus=@{
        current=@{}; locked=$null; skip=$null; skipUntil=0L; awaitSince=$null; waitFrames=0
        noProgressShots=0L; lossEstimate=$null; healthDrops=0; healthLost=0.0; focusedDrops=0
        finishes=0; missedWindows=0; invulnerableWindows=0; releases=0; resets=0; acquisitions=0; bursts=0
    }
    $staleReads=0
    $deadline=if ($FillBackpack) {[double]::PositiveInfinity} else {[Math]::Min($TimeoutSeconds-8,$timer.Elapsed.TotalSeconds+$HarvestSeconds)}
    while ($State.room -eq $diveRoom -and $State.scene.player.oxygen -gt 0 -and $timer.Elapsed.TotalSeconds -lt $deadline) {
        if ($activeDeepHunt -and $State.flags.pause) { throw [OperationCanceledException]::new('The native Shelldiver dive is paused.') }
        if ($deep) { Update-DynamicMagmaFishFocus $State $fishFocus }
        if ($script:diveFull -or (Test-DynamicMagmaPackFull $State ($State.frame-$lastShotFrame -lt 190))) { $reason='dynamic-native-pack-full'; break }
        if ($deep -and $State.flags.player_inventory_open) {
            $State=Close-DynamicMagmaInventory $State
            if ($State.flags.player_inventory_open) { throw 'The native backpack remained open during 1200m fishing.' }
            continue
        }
        if ($State.scene.player.can_use_tool -ne 1) {
            $State=Wait-MagmaDiverReadyForReturn $State
            if ($State.room -ne $diveRoom -or $State.scene.player.can_use_tool -ne 1) { break }
        }
        $player=$State.scene.player
        $anchor=Get-LiveSubmarine $State
        $farthest=[Math]::Max($farthest,(Get-Distance $player $anchor))
        $minimum=[Math]::Min($minimum,[double]$player.oxygen)
        $atEdge=$deep -and ($player.y -lt 62 -or !(Test-OceanSegment $State.room $player $player 11))
        $returnPath=if (!$atEdge) { @(Find-DynamicMagmaPath $State $player $anchor $null) }
        $missingReturn=!@($returnPath).Count -and (Get-Distance $player $anchor) -gt 25
        if ($atEdge -or ($activeDeepHunt -and $missingReturn)) {
            $motion=@(Get-MagmaIIFishMotion $State $previous $motion)
            $previous=$State
            $edge=if ($activeDeepHunt) { Get-DynamicMagmaHuntLeg $State $motion $anchor $trail $hunt -Edge }
                else { Get-DynamicMagmaFishingEdgeEscape $State $motion $anchor }
            if ($edge) {
                $beforeEdge=$State
                $State=Swim-Pulse $State $edge.point 23 2.0 -TrackFrames -AnalogHeading
                $trail.Add($State.scene.player)
                ++$moves
                ++$edgeMoves
                if ($edge.exposure) { ++$exposed }
                $advanced=if ($activeDeepHunt) {
                    ++$hunt.repositionMoves
                    Add-DynamicMagmaHuntObservation $hunt $beforeEdge $State $edge
                } elseif ($player.y -lt 62) { $State.scene.player.y -gt $player.y+2 }
                else { (Get-Distance $player $edge.point) - (Get-Distance $State.scene.player $edge.point) -gt 2 }
                if ($advanced) { $edgeStalls=0; $staleReads=0; continue }
                if ($State.room -ne $diveRoom -or $State.scene.player.can_use_tool -ne 1 -or $State.scene.player.oxygen -le 0) { continue }
            } elseif ($activeDeepHunt) {
                ++$hunt.noProgress
                ++$hunt.noRoute
            }
            ++$edgeStalls
            if ($activeDeepHunt) {
                if ($edgeStalls -ge 11) { Stop-DynamicMagmaBlockedHunt $State $hunt 'edge or return topology' }
            } elseif ($edgeStalls -ge 4) { $reason='dynamic-fishing-edge-escape-stalled'; break }
            $next=Wait-DynamicMagmaHitSnapshot $State
            if ($next.frame -gt $State.frame) { $staleReads=0 } else { ++$staleReads }
            $State=$next
            if ($staleReads -ge 6) { throw 'Original gameplay telemetry stopped during a 1200m edge recovery.' }
            continue
        }
        $edgeStalls=0
        if ($missingReturn) { $reason='dynamic-no-return-topology'; break }
        $distance=Get-DynamicPathLength $player $returnPath
        $reserve=Get-DynamicMagmaReserve $State $distance 35
        if ($player.oxygen -le $reserve) {
            if ($deep -and $player.oxygen_max -le $reserve -and $distance -le 28) {
                $reason='dynamic-tank-too-small-for-return-reserve'; break
            }
            if (!$FillBackpack) { $reason='dynamic-measured-return-reserve'; break }
            $reload=$deep -and $shots -gt $shotsAtLastReload
            $waitAmmo=$reload -and $UseSubmarineAmmoBubble -and ($dryBursts -gt 0 -or $State.scene.bubbleGun.current_ammo_number -eq 0)
            $State=Invoke-DynamicMagmaRefill $State $trail.ToArray() -ReloadBubble:$reload -WaitForBubble:$waitAmmo
            if ($reload) { ++$bubbleReloads; $shotsAtLastReload=$shots }
            ++$refills
            $previous=$null
            $motion=@()
            $lastShotFrame=-10000L
            continue
        }

        if ($deep -and $dryBursts -ge 2) {
            if (!$FillBackpack -or (!$UseSubmarineAmmoBubble -and $dryReloadAttempts -ge 1)) {
                $reason='dynamic-native-bubble-ammo-exhausted'; break
            }
            if ($dryReloadAttempts -ge 3) {
                throw 'The native bubble gun still produced no projectiles after three air refill and reload attempts.'
            }
            $State=Invoke-DynamicMagmaRefill $State $trail.ToArray() -ReloadBubble -WaitForBubble
            ++$bubbleReloads
            ++$refills
            ++$dryReloadAttempts
            $shotsAtLastReload=$shots
            $dryBursts=0
            $previous=$null
            $motion=@()
            continue
        }
        if ($deep -and $UseSubmarineBubble -and $shots -gt $shotsAtLastReload) {
            $gun=$State.scene.bubbleGun
            $air=@{x=$anchor.x-6;y=$anchor.y-24}
            if ($null -ne $gun.current_ammo_number -and $gun.current_ammo_number -le 6 -and
                ($UseSubmarineAmmoBubble -or $State.scene.player.bubble_ammo -gt 0) -and
                (Get-Distance $player $air) -le 87 -and !$State.flags.player_inventory_open -and !$State.flags.pause) {
                $State=Invoke-DynamicMagmaBubbleReload $State
                $shotsAtLastReload=$shots
                ++$bubbleReloads
                continue
            }
        }
        $motion=@(Get-MagmaIIFishMotion $State $previous $motion)
        $previous=$State
        $aim = if ($deep -and $fishFocus.current.Count) {
            Get-DynamicMagmaLockedFishAim $State $player $fishFocus
        } else { Get-DynamicMagmaFishAim $State $player $motion }
        if ($aim) {
            $closest=Get-MagmaNearestFishDistance $State $player
            $burst = if ($aim.track) { 12 }
                elseif ($closest -gt 165 -and $aim.schoolTargets -lt 2) { 30 }
                else { 20 }
            $shootSafe=Test-DynamicMagmaAction $State $motion $player ($burst+8)
            $away=$null
            if (!$shootSafe -and $closest -gt 85 -and
                $player.oxygen -gt (Get-DynamicMagmaReserve $State $distance 128)) {
                $away=Get-DynamicMagmaLeg $State $motion $anchor -AllowBlastExposure
                $shootSafe=$away -and !(($motion | Where-Object {
                    (Get-MagmaIIFishClearance $_ $player $player 0 ($burst+20)) -lt 62
                }) | Select-Object -First 1)
            }
            if ($shootSafe) {
                $beforeOxygen=$player.oxygen
                $beforeShot=$State
                $State=Invoke-DiveTarget $State $aim.target Jellyfish -BubbleFrames $burst
                if ($aim.track) {
                    ++$fishFocus.bursts
                    if ($fishFocus.locked -ne $aim.track) {
                        $fishFocus.locked=$aim.track
                        ++$fishFocus.acquisitions
                        $fishFocus.noProgressShots=0
                        $fishFocus.awaitSince=$null
                    }
                    $spawned=[long]$State.projectiles.bubble-[long]$beforeShot.projectiles.bubble
                    if ($spawned -gt 0) {
                        if ($null -eq $fishFocus.awaitSince) {
                            $fishFocus.awaitSince=$beforeShot.frame
                            $fishFocus.waitFrames=[Math]::Max(45,$aim.flight+$burst+14)
                        }
                        $fishFocus.noProgressShots+=$spawned
                    }
                }
                if ($aim.schoolTargets -ge 2) { ++$schoolBursts }
                $lastShotFrame=$State.frame
                if ($deep -and [long]$State.projectiles.bubble -le [long]$beforeShot.projectiles.bubble) {
                    ++$dryBursts
                    ++$dryBurstsTotal
                } elseif ($deep) {
                    $dryBursts=0
                    $dryReloadAttempts=0
                }
                $minimum=[Math]::Min($minimum,[double]$State.scene.player.oxygen)
                if ($away) {
                    ++$exposed
                    if ($deep -and $State.room -eq $diveRoom) {
                        $motion=@(Get-MagmaIIFishMotion $State $beforeShot $motion)
                        $previous=$State
                        $escape=Get-DynamicMagmaShotEgress $State $motion
                        if ($escape) {
                            $State=Swim-Pulse $State $escape.point 18 2.0 -TrackFrames -AnalogHeading
                            $trail.Add($State.scene.player)
                            $minimum=[Math]::Min($minimum,[double]$State.scene.player.oxygen)
                            ++$moves
                            ++$evasiveMoves
                        }
                    }
                }
                if ($State.scene.player.can_use_tool -eq 0 -and $beforeOxygen-$State.scene.player.oxygen -ge $magmaContactDrop) {
                    ++$script:magmaPossibleContacts
                }
                ++$shots
                $stalls=0
                continue
            }
        }

        ++$replans
        $leg=Get-DynamicMagmaChase $State $motion $anchor $player.oxygen
        if (!$leg -and ($FillBackpack -or $deep)) { $leg=Get-DynamicMagmaScout $State $motion $anchor }
        if ($activeDeepHunt) {
            if ($leg -and ($hunt.blocked | Where-Object { $_.until -gt $State.frame -and (Get-Distance $leg.point $_) -lt 18 } |
                Select-Object -First 1)) { $leg=$null }
            if (!$leg) { $leg=Get-DynamicMagmaHuntLeg $State $motion $anchor $trail $hunt }
        }
        if ($leg) {
            $beforeMove=$State
            $limit=if ((Get-Distance $player $leg.point) -gt 70) { 27 } else { 18 }
            if ($leg.hunt) { ++$hunt.repositionMoves }
            $State=Swim-Pulse $State $leg.point $limit 2.0 -TrackFrames -AnalogHeading
            $advanced=if ($activeDeepHunt) { Add-DynamicMagmaHuntObservation $hunt $beforeMove $State $leg }
                else { (Get-Distance $player $State.scene.player) -gt 2 }
            if ($advanced) { $stalls=0; $staleReads=0 } else { ++$stalls }
            if ($leg.exposure) { ++$exposed }
            ++$moves
            $trail.Add($State.scene.player)
        } else {
            ++$stalls
            if ($activeDeepHunt) { ++$hunt.noProgress; ++$hunt.noRoute }
            $next=Read-MagmaIIRetreatRefresh $State
            if ($next.frame -gt $State.frame) { $staleReads=0 } else { ++$staleReads }
            $State=$next
        }
        if ($staleReads -ge 6) { throw 'Original gameplay telemetry stopped while filling the backpack.' }
        if ($activeDeepHunt -and $stalls -ge 12 -and $State.room -eq $diveRoom -and
            $State.scene.player.can_use_tool -eq 1 -and $State.scene.player.oxygen -gt 0) {
            Stop-DynamicMagmaBlockedHunt $State $hunt 'angle search'
        }
        if (!$activeDeepHunt -and $stalls -ge 7) {
            if (!$FillBackpack) { $reason='dynamic-no-productive-move'; break }
            $stalls=0
        }
    }
    $script:magmaReturnPivots=$trail.ToArray()
    $beforeReturn=$State.scene.player.oxygen
    $spentShots=[long]$State.projectiles.bubble-$startShots
    $returned=Return-ToIsland $State $trail.ToArray()
    $returned | Add-Member -NotePropertyName autoplayDive -NotePropertyValue ([pscustomobject]@{
        dynamicMagmaIIFishing=!$deep;dynamicMagmaIIIFishing=$deep;packFull=$script:diveFull;reason=$reason;shots=$shots;bubbleProjectiles=$spentShots;moves=$moves;replans=$replans
        blastExposureActions=$exposed;possibleContacts=$script:magmaPossibleContacts;startingOxygen=$starting
        minimumHarvestOxygen=$minimum;oxygenBeforeReturn=$beforeReturn;minimumReturnOxygen=$script:magmaMinimumReturnOxygen
        maxDistanceFromSubmarine=[Math]::Round($farthest,1);refills=$refills;evasiveMoves=$evasiveMoves;edgeMoves=$edgeMoves
        huntRepositionMoves=$hunt.repositionMoves;huntBlockedPulses=$hunt.failedPulses;huntNoRouteSamples=$hunt.noRoute
        lastHuntPulse=$hunt.last
        fillBackpack=[bool]$FillBackpack;bubbleReloads=$bubbleReloads;bubbleDryBursts=$dryBurstsTotal
        bubbleSchoolBursts=$schoolBursts;bubbleAmmoBeforeNativeReload=$State.scene.bubbleGun.ammo_before_reloading
        bubbleAmmoSpentOnNativeReload=$State.scene.bubbleGun.ammo_to_spend;elapsedMs=$timer.ElapsedMilliseconds
        measuredFishHealthDrops=$fishFocus.healthDrops;measuredFishHealthLost=$fishFocus.healthLost
        measuredFocusedHealthDrops=$fishFocus.focusedDrops;measuredFishFinishes=$fishFocus.finishes
        fishFocusBursts=$fishFocus.bursts;fishFocusAcquisitions=$fishFocus.acquisitions
        fishFocusMissedWindows=$fishFocus.missedWindows;fishFocusInvulnerableWindows=$fishFocus.invulnerableWindows
        fishFocusReleases=$fishFocus.releases;fishFocusHealthResets=$fishFocus.resets
    })
    return $returned
}
function Get-DynamicMagmaObservedOre($State, $Excluded, [int]$MinY, [int]$MaxY, [int]$MaxAge, [bool]$TrackOre) {
    $observationFrame=[long]$State.scene.player.frame
    foreach ($ore in $State.targets.resources) {
        if ($null -eq $ore.x -or $null -eq $ore.y -or $ore.y -lt $MinY -or $ore.y -gt $MaxY) { continue }
        if ($MaxAge -and $ore.observedFrame -and $observationFrame-$ore.observedFrame -gt $MaxAge) { continue }
        if ($Excluded | Where-Object {
            if ($TrackOre -and $_.track -and $ore.track) { $_.track -eq $ore.track }
            else { (Get-Distance $_ $ore) -lt 15 }
        } | Select-Object -First 1) { continue }
        $ore
    }
}

function Get-DynamicMagmaOrePlan($State, $Anchor, $Excluded, [double]$AvailableOxygen = $State.scene.player.oxygen) {
    $player=$State.scene.player
    $shallow=$State.room -eq 'rm_ocean_magma_01'
    $deep=$State.room -eq 'rm_ocean_magma_03'
    $trackedOre=$shallow -or $deep
    $pathMargin=if ($deep) { 11 } else { 6 }
    $map=$nativeTerrain[$State.room]
    $firstY=if ($shallow) { 0 } else { 188 }
    $lastY=if ($State.room -eq 'rm_ocean_magma_02') { 625 } else { $map.rows.Length*$map.tileHeight }
    $workSteps=if ($shallow) { [Math]::Max(70,$MagmaPlasmaChargeFrames+25) } else { 100 }
    if ($deep) { $workSteps+=48 }
    $age=if ($shallow) { 8 } elseif ($deep) { 12 } else { 0 }
    $candidateCount=if ($deep) { 24 } else { 8 }
    $oreCandidates=@(Get-DynamicMagmaObservedOre $State $Excluded $firstY $lastY $age $trackedOre | Sort-Object {
        if ($trackedOre) { (Get-Distance $player $_)+(Get-Distance $Anchor $_) }
        else { Get-Distance $player $_ }
    } | Select-Object -First $candidateCount)
    $winner=$null
    $best=[double]::PositiveInfinity
    foreach ($ore in $oreCandidates) {
        $sectorPenalty=if ($shallow -and (($MagmaMineSector -eq 'East' -and $ore.x -lt $Anchor.x) -or
            ($MagmaMineSector -eq 'West' -and $ore.x -gt $Anchor.x))) { 24 } else { 0 }
        if ($trackedOre) {
            # Any viable trip must at least reach the pickup circle and return.
            $lowerBound=[Math]::Max(0,(Get-Distance $player $ore)+(Get-Distance $Anchor $ore)-46)
            if ($lowerBound+$sectorPenalty -ge $best -or $AvailableOxygen -le (Get-DynamicMagmaReserve $State $lowerBound $workSteps)) { continue }
        }
        $pickupSites=[Collections.Generic.List[object]]::new()
        $firingSites=[Collections.Generic.List[object]]::new()
        if ((Get-Distance $player $ore) -ge 32 -and (Get-Distance $player $ore) -le $MagmaPlasmaAimRange-2 -and
            (Test-OceanSegment $State.room $player $ore)) { $firingSites.Add($player) }
        for ($bearing=0;$bearing -lt 16;++$bearing) {
            $angle=$bearing*[Math]::PI/8
            $dx=[Math]::Cos($angle)
            $dy=[Math]::Sin($angle)
            $near=@{x=$ore.x+23*$dx;y=$ore.y+23*$dy}
            if (Test-OceanSegment $State.room $near $near 16) { $pickupSites.Add($near) }
            foreach ($radius in 55,92,132,176,216,250) {
                if ($radius -gt $MagmaPlasmaAimRange-2) { continue }
                $shot=@{x=$ore.x+$radius*$dx;y=$ore.y+$radius*$dy}
                if ((Test-OceanSegment $State.room $shot $shot 16) -and
                    (Test-OceanSegment $State.room $shot $ore)) { $firingSites.Add($shot) }
            }
        }
        if (!$pickupSites.Count -or !$firingSites.Count) { continue }
        foreach ($from in ($firingSites | Sort-Object {(Get-Distance $player $_)+.3*(Get-Distance $_ $ore)} | Select-Object -First 4)) {
            $toShot=@(Find-DynamicMagmaPath $State $player $from $null 2600 -MinimumMargin $pathMargin)
            if (!$toShot.Count -and (Get-Distance $player $from) -gt 6) { continue }
            if ($deep -and (Get-Distance $from $Anchor) -gt 10 -and
                !(Find-DynamicMagmaPath $State $from $Anchor $null 2800 -MinimumMargin $pathMargin)) { continue }
            $go=Get-DynamicPathLength $player $toShot
            foreach ($pickup in ($pickupSites | Sort-Object {(Get-Distance $from $_)+(Get-Distance $Anchor $_)} | Select-Object -First 3)) {
                $toCargo=@(Find-DynamicMagmaPath $State $from $pickup $null 2200 -MinimumMargin $pathMargin)
                if (!$toCargo.Count -and (Get-Distance $from $pickup) -gt 6) { continue }
                $toBoat=@(Find-DynamicMagmaPath $State $pickup $Anchor $null 2800 -MinimumMargin $pathMargin)
                if (!$toBoat.Count -and (Get-Distance $pickup $Anchor) -gt 6) { continue }
                $pickupHome=Get-DynamicPathLength $pickup $toBoat
                $cost=$go+(Get-DynamicPathLength $from $toCargo)+$pickupHome
                $required=Get-DynamicMagmaReserve $State $cost $workSteps
                if ($cost+$sectorPenalty -ge $best -or $AvailableOxygen -le $required) { continue }
                $best=$cost+$sectorPenalty
                $winner=@{ore=$ore;shoot=$from;pickup=$pickup;distance=$cost;pickupHome=$pickupHome;minimumOxygen=$required}
            }
        }
    }
    return $winner
}

function Get-DynamicMagmaOreScout($State, $Anchor, $Tracks, $Ore, $Visited, [double]$CurrentReturnDistance) {
    $player=$State.scene.player
    $goals=[Collections.Generic.List[object]]::new()
    foreach ($rock in ($Ore | Sort-Object { Get-Distance $player $_ } | Select-Object -First 3)) {
        $angle=[Math]::Atan2($player.y-$rock.y,$player.x-$rock.x)
        $range=[Math]::Min(125,$MagmaPlasmaAimRange-12)
        foreach ($offset in .65,-.65,1.3,-1.3) {
            $bearing=$angle+$offset
            $point=@{x=$rock.x+$range*[Math]::Cos($bearing);y=$rock.y+$range*[Math]::Sin($bearing)}
            if (Test-OceanSegment $State.room $point $rock) { $goals.Add($point) }
        }
    }
    if (@($State.targets.resources).Count -ge 24) {
        # Stock has two overlapping ore rectangles below y=1024. Moving across their upper approaches changes the nearest-24 list.
        foreach ($point in (@{x=406;y=1056},@{x=721;y=1056},@{x=370;y=1248},@{x=782;y=1248})) { $goals.Add($point) }
    }
    $choice=$null
    $best=[double]::PositiveInfinity
    foreach ($goal in ($goals | Sort-Object { Get-Distance $player $_ })) {
        $distance=Get-Distance $player $goal
        if ($distance -lt 42 -or $distance -gt 236 -or
            ($Visited | Where-Object { (Get-Distance $goal $_) -lt 26 } | Select-Object -First 1)) { continue }
        $out=@(Find-DynamicMagmaPath $State $player $goal $null 2600 -MinimumMargin 11)
        if (!$out.Count) { continue }
        $returnRoute=@(Find-DynamicMagmaPath $State $goal $Anchor $null 2800 -MinimumMargin 11)
        if (!$returnRoute.Count) { continue }
        $distance=(Get-DynamicPathLength $player $out)+(Get-DynamicPathLength $goal $returnRoute)
        $extra=$distance-$CurrentReturnDistance
        if ($extra -gt 270 -or $extra -ge $best -or
            $player.oxygen -le (Get-DynamicMagmaReserve $State $distance ($MagmaPlasmaChargeFrames+110))) { continue }
        $leg=Get-DynamicMagmaLeg $State $Tracks $goal
        if (!$leg -and $MagmaShockResistanceII) { $leg=Get-DynamicMagmaLeg $State $Tracks $goal -AllowBlastExposure }
        if (!$leg) { continue }
        $choice=@{point=$leg.point;goal=$goal;exposure=$leg.exposure}
        $best=$extra
    }
    return $choice
}

function Invoke-DynamicMagmaMiningRefill($State, $Excluded, $Trail, [double]$Deadline, [bool]$AmmoEmpty) {
    $ready=Swim-DynamicMagmaHome $State 27 $Trail -ToAir
    $player=$ready.scene.player
    if ($ready.room -ne $diveRoom -or $ready.flags.pause -or $player.can_use_tool -ne 1) { return @{state=$ready; ready=$false} }
    $anchor=Get-LiveSubmarine $ready
    if (!(Test-DynamicMagmaAir $player $anchor)) { return @{state=$ready; ready=$false} }
    $plan=Get-DynamicMagmaOrePlan $ready $anchor $Excluded $player.oxygen_max
    if (!$plan) { return @{state=$ready; ready=$false} }
    $needed=[Math]::Min([double]$player.oxygen_max,$plan.minimumOxygen+$(if($diveRoom -eq 'rm_ocean_magma_03'){50000}else{8000}))
    $seconds=[Math]::Min(3.0,$Deadline-$timer.Elapsed.TotalSeconds)
    if ($seconds -le .12) { return @{state=$ready; ready=$false} }
    if ($player.oxygen -lt $needed -or ($AmmoEmpty -and $player.plasma_ammo -le 0)) {
        try {
            $ready=Wait-DiveSnapshot {
                param($sample)
                $sample.flags.pause -or $sample.flags.transitioning -or $sample.scene.player.can_use_tool -ne 1 -or
                    ($sample.scene.player.oxygen -ge $needed -and
                        (!$AmmoEmpty -or $sample.scene.player.plasma_ammo -gt 0))
            } 'native Magma I mining air or ammo to recover' -AllowIsland -AllowEmptyOxygen -MaxWaitSeconds $seconds
        } catch {
            if ($_.Exception.Message -ne 'Timed out waiting for native Magma I mining air or ammo to recover.') { throw }
            $ready=Read-DiveSnapshot
        }
    }
    return @{
        state=$ready
        ready=$ready.room -eq $diveRoom -and !$ready.flags.pause -and $ready.scene.player.can_use_tool -eq 1 -and
            $ready.scene.player.oxygen -gt $plan.minimumOxygen -and (!$AmmoEmpty -or $ready.scene.player.plasma_ammo -gt 0)
    }
}

function Invoke-DynamicMagmaResource($State) {
    $script:magmaMinFishClearance=[double]::PositiveInfinity
    $script:magmaPossibleContacts=0
    $script:magmaPartialRetreats=0
    $script:magmaMinimumReturnOxygen=$null
    $trail=[Collections.Generic.List[object]]::new()
    $excluded=[Collections.Generic.List[object]]::new()
    $deep=$State.room -eq 'rm_ocean_magma_03'
    $shallow=$State.room -eq 'rm_ocean_magma_01'
    $chainOre=$shallow -or $deep
    $starting=[double]$State.scene.player.oxygen
    $minimum=$starting
    $farthest=0.0
    $startShots=[long]$State.projectiles.plasma
    $plan=$null
    $previous=$null
    $motion=@()
    $shots=0
    $moves=0
    $exposed=0
    $replans=0
    $stalls=0
    $targetHits=0L
    $broken=$false
    $sitesReached=0
    $oreCleared=0
    $refills=0
    $resupplyAttempts=0
    $resupplyAvailable=$true
    $oreRefreshes=0
    $maxObservedOre=0
    $lastObservedOre=0
    $lastEligibleOre=0
    $spawnWaits=0
    $spawnWatchedAt=-1
    $scoutMoves=0
    $scoutDeadline=0.0
    $scoutVisited=[Collections.Generic.List[object]]::new()
    $holds=[Collections.Generic.List[int]]::new()
    $minimumBurst=$MagmaPlasmaChargeFrames+11
    $reason='dynamic-mining-time'
    $deadline=[Math]::Min($TimeoutSeconds-10,$timer.Elapsed.TotalSeconds+$HarvestSeconds)
    while ($State.room -eq $diveRoom -and $State.scene.player.oxygen -gt 0 -and $timer.Elapsed.TotalSeconds -lt $deadline) {
        if ($script:diveFull) { $reason='dynamic-native-pack-full'; break }
        if ($chainOre -and $State.flags.pause) { throw [OperationCanceledException]::new('The native Shelldiver dive is paused.') }
        if ($chainOre -and $State.flags.player_inventory_open) {
            $State=Close-DynamicMagmaInventory $State
            if ($State.room -ne $diveRoom -or $State.flags.player_inventory_open) { break }
        }
        if ($State.scene.player.can_use_tool -ne 1) {
            $State=Wait-MagmaDiverReadyForReturn $State
            if ($State.room -ne $diveRoom -or $State.scene.player.can_use_tool -ne 1) { break }
        }
        $player=$State.scene.player
        $minimum=[Math]::Min($minimum,[double]$player.oxygen)
        $anchor=Get-LiveSubmarine $State
        $farthest=[Math]::Max($farthest,(Get-Distance $player $anchor))
        $returnPath=@(Find-DynamicMagmaPath $State $player $anchor $null 2800)
        if (!$returnPath.Count -and (Get-Distance $player $anchor) -gt 27) { $reason='dynamic-no-return-topology'; break }
        $returnDistance=Get-DynamicPathLength $player $returnPath
        $returnAllowance=if ($deep) { 90 } else { 40 }
        if ($player.oxygen -le (Get-DynamicMagmaReserve $State $returnDistance $returnAllowance)) {
            if ($deep -and $UseSubmarineBubble -and $resupplyAvailable -and $timer.Elapsed.TotalSeconds -lt $deadline-3) {
                ++$resupplyAttempts
                $refill=Invoke-DynamicMagmaMiningRefill $State $excluded.ToArray() $trail.ToArray() $deadline $false
                $State=$refill.state
                $plan=$null
                $previous=$null
                $motion=@()
                $resupplyAvailable=$refill.ready
                if($refill.ready){++$refills;continue}
            }
            $reason='dynamic-mining-return-reserve'
            break
        }
        $motion=@(Get-MagmaIIFishMotion $State $previous $motion)
        $previous=$State

        if (!$plan) {
            $plan=Get-DynamicMagmaOrePlan $State $anchor $excluded.ToArray()
            if ($deep) {
                $fresh=Read-DiveSnapshot
                if ($fresh.room -ne $diveRoom -or $fresh.flags.pause -or $fresh.scene.player.can_use_tool -ne 1 -or
                    $fresh.scene.player.oxygen -le (Get-DynamicMagmaReserve $State $returnDistance $returnAllowance)) {
                    $State=$fresh
                    $reason='dynamic-mining-reserve-after-planning'
                    break
                }
                if ($plan -and ($fresh.scene.player.oxygen -le $plan.minimumOxygen -or
                    (Get-Distance $player $fresh.scene.player) -gt 12)) { $plan=$null }
                $previous=$State
                $State=$fresh
                $player=$State.scene.player
                $motion=@(Get-MagmaIIFishMotion $State $previous $motion)
                $previous=$State
            }
            ++$replans
            $targetHits=[long]$State.projectiles.plasma
            $targetShots=0
            $broken=$false
        }
        $ammoEmpty=$chainOre -and $UseSubmarineAmmoBubble -and $null -ne $player.plasma_ammo -and $player.plasma_ammo -le 0 -and
            $null -ne $State.scene.plasmaGun.current_ammo_number -and $State.scene.plasmaGun.current_ammo_number -le 0
        $oxygenLow=$chainOre -and !$plan -and $player.oxygen -lt .66*$player.oxygen_max
        if ($resupplyAvailable -and $UseSubmarineBubble -and ($ammoEmpty -or $oxygenLow) -and $resupplyAttempts -lt 2 -and
            $timer.Elapsed.TotalSeconds -lt $deadline-2) {
            $reachable=$plan
            if (!$reachable) { $reachable=Get-DynamicMagmaOrePlan $State $anchor $excluded.ToArray() $player.oxygen_max }
            if ($reachable) {
                ++$resupplyAttempts
                $refill=Invoke-DynamicMagmaMiningRefill $State $excluded.ToArray() $trail.ToArray() $deadline $ammoEmpty
                $State=$refill.state
                $plan=$null
                $resupplyAvailable=$refill.ready
                if ($resupplyAvailable -and ($State.scene.player.oxygen -gt $player.oxygen -or $ammoEmpty)) { ++$refills }
                continue
            }
        }
        if ($deep -and !$plan -and !$ammoEmpty) {
            $lastObservedOre=@($State.targets.resources).Count
            $maxObservedOre=[Math]::Max($maxObservedOre,$lastObservedOre)
            $eligible=@(Get-DynamicMagmaObservedOre $State $excluded.ToArray() 188 1600 12 $true)
            $lastEligibleOre=$eligible.Count
            $seconds=$timer.Elapsed.TotalSeconds
            if (!$scoutDeadline) { $scoutDeadline=[Math]::Min($deadline-.30,$seconds+1.15) }
            if (($eligible.Count -or $lastObservedOre -ge 24) -and $scoutMoves -lt 8 -and $seconds -lt $scoutDeadline) {
                $scout=Get-DynamicMagmaOreScout $State $anchor $motion $eligible $scoutVisited $returnDistance
                if ($scout -and $timer.Elapsed.TotalSeconds -lt $scoutDeadline) {
                    $State=Swim-Pulse $State $scout.point 27 2.0 -TrackFrames -AnalogHeading
                    $trail.Add($State.scene.player)
                    ++$scoutMoves
                    ++$moves
                    if ($scout.exposure) { ++$exposed }
                    if ((Get-Distance $State.scene.player $player) -lt 2 -or
                        (Get-Distance $State.scene.player $scout.goal) -lt 44) { $scoutVisited.Add($scout.goal) }
                    continue
                }
            }
            if (!$eligible.Count -and $spawnWatchedAt -ne $oreCleared -and $player.y -ge 936 -and
                $seconds+.12 -lt $scoutDeadline -and (Test-DynamicMagmaAction $State $motion $player 120) -and
                $player.oxygen -gt (Get-DynamicMagmaReserve $State $returnDistance 185)) {
                $spawnWatchedAt=$oreCleared
                ++$spawnWaits
                $watchEnd=[long]$State.scene.player.frame+120
                $wait=[Math]::Min(.65,$scoutDeadline-$timer.Elapsed.TotalSeconds)
                if ($wait -gt .08) {
                    try {
                        $State=Wait-DiveSnapshot {
                            param($sample)
                            $sample.flags.pause -or $sample.flags.transitioning -or $sample.scene.player.can_use_tool -ne 1 -or
                                $sample.scene.player.frame -ge $watchEnd -or
                                [bool](Get-DynamicMagmaObservedOre $sample $excluded.ToArray() 188 1600 12 $true | Select-Object -First 1)
                        } 'a fresh 1200m ore spawn window' -AllowIsland -AllowEmptyOxygen -MaxWaitSeconds $wait
                    } catch {
                        if ($_.Exception.Message -ne 'Timed out waiting for a fresh 1200m ore spawn window.') { throw }
                        $State=Read-DiveSnapshot
                    }
                    continue
                }
            }
            $reason=if ($lastObservedOre -ge 24) { 'dynamic-mining-observation-list-full' }
                elseif ($eligible.Count) { 'dynamic-mining-visible-ore-unreachable' } else { 'dynamic-mining-no-fresh-ore' }
            break
        }
        if (!$plan -or $ammoEmpty) {
            if ($chainOre -and !$ammoEmpty -and $oreRefreshes -lt 2 -and
                (!$shots -or ($State.targets.resources | Where-Object {
                    $_.observedFrame -and $State.frame-$_.observedFrame -gt 8
                } | Select-Object -First 1))) {
                $State=Read-MagmaIIRetreatRefresh $State
                ++$oreRefreshes
                continue
            }
            $reason=if ($ammoEmpty) { 'dynamic-mining-ammo-spent' } else { 'dynamic-no-collectable-rock' }
            break
        }
        $oreRefreshes=0
        if ($deep) {
            $maxObservedOre=[Math]::Max($maxObservedOre,@($State.targets.resources).Count)
            $scoutDeadline=0.0
            $scoutVisited.Clear()
            $minimumTrip=(Get-Distance $player $plan.pickup)+$plan.pickupHome
            $minimumWork=if ($broken) { 45 } else { $minimumBurst+75 }
            if ($player.oxygen -le (Get-DynamicMagmaReserve $State $minimumTrip $minimumWork)) {
                $reason='dynamic-mining-cargo-return-reserve'
                break
            }
        }
        $rock=$plan.ore
        $liveOre=$State.targets.resources | Where-Object {
            if ($chainOre -and $_.track -and $rock.track) { $_.track -eq $rock.track }
            else { (Get-Distance $_ $rock) -lt 13 }
        } | Select-Object -First 1
        $freshLimit=if ($targetShots -gt 0) { 3 } else { 8 }
        $oreFrame=if ($deep) { [long]$player.frame } else { [long]$State.frame }
        if ($deep -and !$targetShots) { $freshLimit=12 }
        $staleOre=$chainOre -and $liveOre -and $liveOre.observedFrame -and $oreFrame-$liveOre.observedFrame -gt $freshLimit
        if ($staleOre) {
            # Target entries remain in the bridge for 30 steps after a destroyed instance.
            if ($targetShots -gt 0 -and [long]$State.projectiles.plasma -gt $targetHits -and
                (Test-DynamicMagmaAction $State $motion $player 23)) {
                $State=Read-MagmaIIRetreatRefresh $State
                continue
            }
            $liveOre=$null
        }
        $distanceToOre=Get-Distance $player $rock
        if (!$broken -and !$liveOre -and !$staleOre -and $targetShots -gt 0 -and [long]$State.projectiles.plasma -gt $targetHits -and
            $distanceToOre -le $MagmaPlasmaAimRange+24) {
            $broken=$true
            ++$oreCleared
        }
        if ($broken -and $distanceToOre -le 28) {
            ++$sitesReached
            $reason='dynamic-mining-cargo-reached'
            if (!$chainOre) { break }
            $excluded.Add($rock)
            $plan=$null
            $stalls=0
            continue
        }
        if (!$broken -and (!$liveOre -and (Get-Distance $player $plan.shoot) -lt 20 -or $targetShots -ge 4)) {
            $excluded.Add($rock)
            $plan=$null
            continue
        }
        $ray=$liveOre -and $distanceToOre -ge 32 -and $distanceToOre -le $MagmaPlasmaAimRange -and
            (Test-OceanSegment $State.room $player $liveOre)
        $fired=$false
        if (!$broken -and $ray) {
            foreach ($burst in ($PlasmaHoldFrames,110,70,$minimumBurst | Sort-Object -Descending -Unique)) {
                $safeDistance=if ($deep) { [Math]::Max($minimumTrip,$returnDistance) } else { $returnDistance }
                $safeAction=if ($deep) { $burst+50 } else { $burst }
                if ($burst -gt $PlasmaHoldFrames -or $burst -lt $minimumBurst -or $player.oxygen -le
                    (Get-DynamicMagmaReserve $State $safeDistance $safeAction) -or
                    ($shallow -and $timer.Elapsed.TotalSeconds+.30 -ge $deadline)) { continue }
                $fireNow=Test-DynamicMagmaAction $State $motion $player ($burst+4)
                $riskShot=$false
                if (!$fireNow -and (!$shallow -or $MagmaShockResistance) -and $burst -le 70 -and
                    $player.oxygen -gt (Get-DynamicMagmaReserve $State $returnDistance ($burst+100))) {
                    $riskShot=!(($motion | Where-Object {
                        (Get-MagmaIIFishClearance $_ $player $player 0 ($burst+24)) -lt 62
                    }) | Select-Object -First 1)
                    $fireNow=$riskShot
                }
                if (!$fireNow) { continue }
                $State=Invoke-DiveTarget $State $liveOre Resource -PlasmaFrames $burst
                if ($riskShot) { ++$exposed }
                $holds.Add($burst)
                ++$shots
                ++$targetShots
                $fired=$true
                $stalls=0
                break
            }
        }
        if ($fired) { continue }

        $goal=if ($broken) { $plan.pickup } else { $plan.shoot }
        $nearWall=$chainOre -and !(Test-OceanSegment $State.room $player $player 11)
        $leg=Get-DynamicMagmaLeg $State $motion $goal -NearWallRecovery:$nearWall
        if (!$leg -and (!$shallow -or $MagmaShockResistance) -and
            $player.oxygen -gt (Get-DynamicMagmaReserve $State $returnDistance 130)) {
            $leg=Get-DynamicMagmaLeg $State $motion $goal -AllowBlastExposure -NearWallRecovery:$nearWall
        }
        if ($leg) {
            $State=Swim-Pulse $State $leg.point 27 2.0 -TrackFrames -AnalogHeading
            $trail.Add($State.scene.player)
            if ($leg.exposure) { ++$exposed }
            ++$moves
            if ((Get-Distance $player $State.scene.player) -gt 2) { $stalls=0 } else { ++$stalls }
        } else {
            $State=Read-MagmaIIRetreatRefresh $State
            ++$stalls
        }
        if ($stalls -ge 5) {
            $excluded.Add($rock)
            $plan=$null
            $stalls=0
        }
    }
    $script:magmaReturnPivots=$trail.ToArray()
    $beforeReturn=$State.scene.player.oxygen
    $hits=[long]$State.projectiles.plasma-$startShots
    $returned=Return-ToIsland $State $trail.ToArray()
    $returned | Add-Member -NotePropertyName autoplayDive -NotePropertyValue ([pscustomobject]@{
        packFull=$script:diveFull;dynamicMagmaIResource=$shallow;dynamicMagmaIIResource=!$deep -and !$shallow;dynamicMagmaIIIResource=$deep
        magmaSectorPreference=if ($shallow) { $MagmaMineSector };multiOreRoute=$chainOre
        reason=$reason;shots=$shots;plasmaProjectiles=$hits;moves=$moves;replans=$replans
        plasmaChargeFrames=$MagmaPlasmaChargeFrames;plasmaPulseFrames=$holds.ToArray()
        oreTargetsCleared=$oreCleared;oreSitesReached=$sitesReached;resupplyAttempts=$resupplyAttempts;nativeRefills=$refills
        oreScoutMoves=$scoutMoves;oreSpawnWaits=$spawnWaits;maxObservedOre=$maxObservedOre
        lastObservedOre=$lastObservedOre;lastEligibleOre=$lastEligibleOre
        blastExposureActions=$exposed;plannedOre=$plan.ore;plannedRoundTrip=$plan.distance;attemptedPickup=$broken -or $sitesReached -gt 0
        startingOxygen=$starting;minimumHarvestOxygen=$minimum;oxygenBeforeReturn=$beforeReturn
        minimumReturnOxygen=$script:magmaMinimumReturnOxygen;maxDistanceFromSubmarine=[Math]::Round($farthest,1)
        elapsedMs=$timer.ElapsedMilliseconds
    })
    return $returned
}
