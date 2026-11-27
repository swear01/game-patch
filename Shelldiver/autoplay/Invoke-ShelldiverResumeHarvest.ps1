[CmdletBinding()]
param([int]$ExpectedPid,[string]$OutputDirectory=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$control=Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$dive=Join-Path $PSScriptRoot 'Invoke-ShelldiverDive.ps1'
$session=Join-Path $PSScriptRoot 'Invoke-ShelldiverSession.ps1'
$source=Join-Path $PSScriptRoot 'ShelldiverTerrain.original.json'
$map=(Get-Content $source -Raw|ConvertFrom-Json).rooms.rm_ocean_magma_03
if (!('ShelldiverDynamicRoute' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'ShelldiverDynamicRoute.cs')}
$timer=[Diagnostics.Stopwatch]::StartNew()
function Read-Game {
    $s=& $control -Action snapshot
    if($s.pid -ne $ExpectedPid){throw 'The native game process changed.'}
    return $s
}
function Write-Event($eventName,$state,$detail) {
    [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o');event=$eventName;elapsedMs=$timer.ElapsedMilliseconds;
        frame=$state.frame;room=$state.room;oxygen=$state.scene.player.oxygen;x=$state.scene.player.x;y=$state.scene.player.y;detail=$detail}|
        ConvertTo-Json -Depth 8 -Compress|Add-Content (Join-Path $OutputDirectory 'native-1200-continued-harvest.jsonl')
}
function Finish-InsuredCatch($State) {
    if ($State.room -ne 'rm_ocean_magma_03' -or $State.scene.player.oxygen -gt 0 -or $State.scene.player.can_use_tool -ne 0) {
        throw 'No native oxygen-loss result to settle.'
    }
    Add-Type -AssemblyName System.Drawing
    $capturePath=Join-Path $OutputDirectory 'native-red-latest-loss-screen.png'
    $wait=[Diagnostics.Stopwatch]::StartNew()
    do {
        $capture=& (Join-Path $PSScriptRoot 'Get-ShelldiverFrame.ps1') -OutputPath $capturePath
        if (!$capture.foregroundUnchanged -or $capture.pid -ne $ExpectedPid) { throw 'Game-only capture changed.' }
        $original=[Drawing.Image]::FromFile($capturePath)
        try {
            $view=[Drawing.Bitmap]::new($original,720,405)
            try {
                $green=0
                $yellow=0
                for($y=285;$y -le 307;$y+=2) {
                    for($x=222;$x -le 377;$x+=2) {
                        $c=$view.GetPixel($x,$y)
                        if($x -ge 311 -and $c.R -gt 195 -and $c.G -gt 160 -and $c.B -lt 105){++$yellow}
                        if($x -lt 289 -and $c.G -gt 125 -and $c.R -lt 155 -and $c.B -lt 125 -and $c.G -gt $c.R+35){++$green}
                    }
                }
            } finally { $view.Dispose() }
        } finally { $original.Dispose() }
        if($yellow -ge 150 -and $green -ge 150){
            $land=& $session -Action FinishResult -Depth 1200 -ResultVerified -TimeoutSeconds 45
            if($land.room -ne 'rm_main_island' -or $land.pid -ne $ExpectedPid -or !$land.nativeSaveAfter.sha256){throw 'Native insurance landing was not saved.'}
            Write-Event 'insured-island' (Read-Game) $land.nativeSaveAfter
            return $land
        }
        Start-Sleep -Milliseconds 300
    } while($wait.Elapsed.TotalSeconds -lt 12)
    throw 'The native expedition result buttons did not appear.'
}
function Refill-AfterInterruption {
    $s=Read-Game
    if($s.room -ne 'rm_ocean_magma_03' -or $s.scene.player.oxygen -le 0){throw 'A surviving Magma Abyss diver is required.'}
    if($s.flags.pause){
        $null=& $control -Action click -ParametersJson '{"x":0.064,"y":0.458,"button":1,"holdFrames":1}'
        $resume=[Diagnostics.Stopwatch]::StartNew()
        do {Start-Sleep -Milliseconds 30;$s=Read-Game} while($s.flags.pause -and $resume.Elapsed.TotalSeconds -lt 2.5)
        if($s.flags.pause){throw 'The stock Resume button did not resume this expedition.'}
    }
    for($i=0;$i -lt 100;$i++){
        $p=$s.scene.player
        $sub=$s.scene.submarineLeave
        if($s.room -ne 'rm_ocean_magma_03' -or $p.oxygen -le 0 -or $s.flags.player_inventory_open){return $s}
        $cx=$sub.x-6
        $cy=$sub.y-24
        $dx=$cx-$p.x
        $dy=$cy-$p.y
        $distance=[Math]::Sqrt($dx*$dx+$dy*$dy)
        if($distance -lt 95 -and $p.oxygen -ge .9*$p.oxygen_max -and $p.can_use_tool -eq 1){return $s}
        $gx=if($distance -gt 95){$cx-68*$dx/$distance}else{$cx}
        $gy=if($distance -gt 95){$cy-68*$dy/$distance}else{$cy}
        $route=[ShelldiverDynamicRoute]::Find($map.rows,$map.tileWidth,$map.tileHeight,$p.x,$p.y,$gx,$gy,6,2,4200,$null)
        if(!$route.Count -and $distance -gt 95){throw 'No terrain-valid escape toward native air.'}
        if($route.Count){$dx=$route[0].x-$p.x;$dy=$route[0].y-$p.y}
        $major=[Math]::Max(1,[Math]::Max([Math]::Abs($dx),[Math]::Abs($dy)))
        $frames=[int][Math]::Clamp($major/2,8,28)
        $values=@{left=[Math]::Max(0,-$dx/$major);right=[Math]::Max(0,$dx/$major);up=[Math]::Max(0,-$dy/$major);
            down=[Math]::Max(0,$dy/$major);is_moving_any=$true;is_moving_horizontal=([Math]::Abs($dx/$major) -gt .08)}
        $reply=& $control -Action input -ParametersJson (@{frames=$frames;values=$values}|ConvertTo-Json -Compress)
        $actionClock=[Diagnostics.Stopwatch]::StartNew()
        do {Start-Sleep -Milliseconds 30;$s=Read-Game} while($s.frame -lt $reply.frame+$frames -and $s.scene.player.oxygen -gt 0 -and $actionClock.Elapsed.TotalSeconds -lt 1.5)
    }
    throw 'Air approach did not yield a verified native refill.'
}
$s=Read-Game
$rankStatus=& $session -Action Status
if($rankStatus.nativeSave.magmaShockResistance -ne $true -or !$rankStatus.nativeSave.submarineBubbleOwned){throw 'Required native air and resistance passives are absent.'}
for($recoveries=0;$recoveries -lt 10;$recoveries++){
    try {
        Write-Event 'recovery-start' $s $null
        if($s.scene.player.oxygen -le 0){return Finish-InsuredCatch $s}
        $s=Refill-AfterInterruption
        Write-Event 'air' $s $null
        if($s.scene.player.oxygen -le 0){throw 'Native oxygen loss.'}
        $argsDive=@{Action='Dive';Kind='Jellyfish';MagmaShockResistance=$true;MagmaShockFrequency=[bool]$rankStatus.nativeSave.magmaShockFrequency;
            MagmaShockResistanceII=[bool]$rankStatus.nativeSave.magmaShockResistanceII;UseSubmarineAmmoBubble=[bool]$rankStatus.nativeSave.submarineAmmoBubbleOwned;UseSubmarineBubble=$true;FillBackpack=$true;HoldResult=$true;TimeoutSeconds=90}
        foreach($name in 'MagmaBubblePenetration','MagmaBubbleProjectileSpeed','MagmaBubbleProjectileLifetime'){if($rankStatus.nativeSave.$name){$argsDive[$name]=$rankStatus.nativeSave.$name}}
        $result=& $dive @argsDive
        $result|ConvertTo-Json -Depth 22|Set-Content (Join-Path $OutputDirectory 'native-red-resumed-full-result.json')
        $s=Read-Game
        Write-Event 'harvest-result' $s $result.autoplayDive
        $status=& $session -Action Status
        if($status.room -ne 'rm_ocean_magma_03' -or $status.oxygen -le 0 -or !$status.nativeSave.sha256 -or $status.canUseTool -ne 0){throw 'Native landing receipt is incomplete.'}
        $finish=& $session -Action FinishResult -Depth 1200 -ResultVerified
        Write-Event 'island' (Read-Game) $finish.nativeSaveAfter
        return $finish
    } catch {
        $s=Read-Game
        $err=$_.Exception.Message
        Write-Event 'interrupted' $s $err
        if($s.room -ne 'rm_ocean_magma_03'){throw}
        if($s.scene.player.oxygen -le 0){return Finish-InsuredCatch $s}
        if(!$s.flags.pause -and !$s.flags.transitioning){
            $null=& $control -Action input -ParametersJson '{"frames":2,"values":{"pause":true}}'
            Start-Sleep -Milliseconds 120
        }
        if($err -notmatch 'regain control|No safe dynamic|native 1200m hit recovery|native refill|No terrain-valid|original submarine air'){throw}
        $s=Read-Game
    }
}
throw 'Repeated recovery requires inspection of the native game view.'
