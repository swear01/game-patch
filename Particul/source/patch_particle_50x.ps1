param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$backup = "$bundle.before-50x-20260904.js"
$scale = 50

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
if (-not (Test-Path -LiteralPath $backup)) { throw "Backup not found: $backup" }

$originalHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
$backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
if ($originalHash -ne $backupHash) {
    throw 'The renderer bundle no longer matches the backup; refusing to overwrite an unexpected change.'
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "${Label}: expected 1 match, found $count" }
    return $Text.Replace($Old, $New)
}

$source = [IO.File]::ReadAllText($bundle)

# Main simulation clock: scale timers and process every elapsed simulated second.
$tickStart = $source.IndexOf('key:"tick",value:function(e)', [StringComparison]::Ordinal)
if ($tickStart -lt 0) { throw 'Main tick method not found' }
$tickEnd = $source.IndexOf('},{key:', $tickStart + 10, [StringComparison]::Ordinal)
if ($tickEnd -lt 0) { throw 'Main tick method end not found' }
$tick = $source.Substring($tickStart, $tickEnd - $tickStart)
$tick = Replace-Once $tick 'this.totalTime+=e' 'this.totalTime+=50*e' 'totalTime scale'
$tick = Replace-Once $tick 'i.timer+=e' 'i.timer+=50*e' 'auto-clicker timer scale'
$tick = Replace-Once $tick 'i.jammedTimer-=e' 'i.jammedTimer-=50*e' 'jam timer scale'
$tick = Replace-Once $tick 'A.timer+=e' 'A.timer+=50*e' 'auto-seller timer scale'
$tick = Replace-Once $tick 'this.mouseDrill.timer+=e' 'this.mouseDrill.timer+=50*e' 'mouse-drill timer scale'

$tailPrefix = 'if(this.totalTime>1e3&&(this.seconds+=1,this.totalTime=0,this.seconds%this.monthLength===0)){'
$tailStart = $tick.IndexOf('if(this.totalTime>1e3&&', [StringComparison]::Ordinal)
if ($tailStart -lt 0) { throw 'Main elapsed-second block not found' }
$tail = $tick.Substring($tailStart)
if (-not $tail.StartsWith($tailPrefix, [StringComparison]::Ordinal) -or -not $tail.EndsWith('}}}', [StringComparison]::Ordinal)) {
    throw 'Unexpected main elapsed-second block shape'
}
$monthBody = $tail.Substring($tailPrefix.Length, $tail.Length - $tailPrefix.Length - 3)
$newTail = 'for(;this.totalTime>=1e3;this.totalTime-=1e3){this.seconds+=1;if(this.seconds%this.monthLength===0){' + $monthBody + '}}}}'
$tick = $tick.Substring(0, $tailStart) + $newTail
$source = $source.Substring(0, $tickStart) + $tick + $source.Substring($tickEnd)

# Main particle simulation: run the particle compute pass 50 times per animation frame.
$mainComputeOld = 'var r=t.beginComputePass();r.setPipeline(this.computePipeline),r.setBindGroup(0,this.computeBindGroup),r.dispatchWorkgroups(Math.ceil(this.cellCount/256)),r.end();var i=t.beginComputePass();'
$mainComputeNew = 'for(var r=0;r<50;r++){var i=t.beginComputePass();i.setPipeline(this.computePipeline),i.setBindGroup(0,this.computeBindGroup),i.dispatchWorkgroups(Math.ceil(this.cellCount/256)),i.end()}var i=t.beginComputePass();'
$source = Replace-Once $source $mainComputeOld $mainComputeNew 'main particle compute loop'

# Plinko simulation: scale its clock and run its independent compute pass 50 times.
$plinkoFrameOld = 'key:"frame",value:function(){this.i++;var e=1===this.i?0:performance.now()-this.t;'
$plinkoFrameNew = 'key:"frame",value:function(){this.i++;var e=1===this.i?0:50*(performance.now()-this.t);'
$source = Replace-Once $source $plinkoFrameOld $plinkoFrameNew 'Plinko clock'
$plinkoComputeOld = 'var t=this.device.createCommandEncoder(),n=t.beginComputePass();n.setPipeline(this.computePipeline),n.setBindGroup(0,this.computeBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();'
$plinkoComputeNew = 'var t=this.device.createCommandEncoder();for(var o=0;o<50;o++){var n=t.beginComputePass();n.setPipeline(this.computePipeline),n.setBindGroup(0,this.computeBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();}'
$source = Replace-Once $source $plinkoComputeOld $plinkoComputeNew 'Plinko compute loop'

[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))

$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Patched: $bundle"
Write-Output "Original/backup SHA256: $backupHash"
Write-Output "Patched SHA256: $newHash"
