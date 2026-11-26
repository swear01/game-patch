param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$backup = "$bundle.before-extractor-queue-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
if (-not (Test-Path -LiteralPath $backup)) { throw "Backup not found: $backup" }

$sourceHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
$backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
if ($sourceHash -ne $backupHash) {
    throw 'The renderer bundle no longer matches the extractor-queue backup; refusing to overwrite an unexpected change.'
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "${Label}: expected 1 match, found $count" }
    return $Text.Replace($Old, $New)
}

$source = [IO.File]::ReadAllText($bundle)

# Keep pending extractor spawns in the simulation object until a GPU step can consume them.
$mainClassStart = $source.IndexOf('var Pe=function()', [StringComparison]::Ordinal)
$tickStart = $source.IndexOf('key:"tick",value:function(e)', [StringComparison]::Ordinal)
if ($mainClassStart -lt 0 -or $tickStart -lt 0 -or $mainClassStart -ge $tickStart) { throw 'Main simulation boundaries not found' }
$mainConstructor = $source.Substring($mainClassStart, $tickStart - $mainClassStart)
$mainConstructor = Replace-Once $mainConstructor 'this.autoClickers=[],this.autoSellers=[],this.ascensions=[]' 'this.autoClickers=[],this.autoSellers=[],this.pendingSpawns=[],this.ascensions=[]' 'pending spawn state'
$source = $source.Substring(0, $mainClassStart) + $mainConstructor + $source.Substring($tickStart)

# Add a queue and flush one spawn per unique emitter cell on each simulation step.
$addStart = $source.IndexOf('key:"addParticleAt",value:function(e,t,n)', [StringComparison]::Ordinal)
if ($addStart -lt 0 -or $addStart -ge $tickStart) { throw 'Main addParticleAt method not found' }
$addEnd = $source.IndexOf('},{key:', $addStart + 10, [StringComparison]::Ordinal)
if ($addEnd -lt 0) { throw 'Main addParticleAt method end not found' }
$addMethod = $source.Substring($addStart, $addEnd - $addStart)
$queueMethods = '},{key:"queueParticleAt",value:function(e,t,n,r){this.pendingSpawns.push([e,t,n,!!r])}},{key:"flushParticleSpawns",value:function(){var e={},t=[];for(var n=0;n<this.pendingSpawns.length;n++){var r=this.pendingSpawns[n],i=r[0]+":"+r[1];e[i]||(e[i]=!0,t.push(r),this.pendingSpawns.splice(n,1),n--)}for(var o=0;o<t.length;o++){var a=t[o];this.addParticleAt(a[0],a[1],a[2],a[3])}}'
$source = $source.Substring(0, $addStart) + $addMethod + $queueMethods + $source.Substring($addEnd)

# Queue extractor writes instead of overwriting the same output cell repeatedly in one tick.
$tickStart = $source.IndexOf('key:"tick",value:function(e)', [StringComparison]::Ordinal)
$tickEnd = $source.IndexOf('},{key:', $tickStart + 10, [StringComparison]::Ordinal)
if ($tickStart -lt 0 -or $tickEnd -lt 0) { throw 'Main tick method boundaries not found after insertion' }
$tick = $source.Substring($tickStart, $tickEnd - $tickStart)
$tick = Replace-Once $tick 'this.addParticleAt(i.x,Math.max(0,this.height-this.boxHeight-4))' 'this.queueParticleAt(i.x,Math.max(0,this.height-this.boxHeight-4))' 'extractor primary spawn'
$tick = Replace-Once $tick 'this.addParticleAt(i.x+1,Math.max(0,this.height-this.boxHeight-4))' 'this.queueParticleAt(i.x+1,Math.max(0,this.height-this.boxHeight-4))' 'extractor boosted spawn'
$tick = Replace-Once $tick 'this.addParticleAt(i.x-1,Math.max(0,this.height-this.boxHeight-4),!1,!0)' 'this.queueParticleAt(i.x-1,Math.max(0,this.height-this.boxHeight-4),!1,!0)' 'extractor overdrive spawn'
$source = $source.Substring(0, $tickStart) + $tick + $source.Substring($tickEnd)

# Submit each compute step separately so queued writes and GPU movement are interleaved.
$mainCoreOld = 'var t=this.device.createCommandEncoder();t.clearBuffer(this.activeCountBuffer),t.clearBuffer(this.totalCountBuffer),t.clearBuffer(this.gwCount);var n=t.beginComputePass();n.setPipeline(this.deletePipeline),n.setBindGroup(0,this.deleteBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();for(var r=0;r<50;r++){var i=t.beginComputePass();i.setPipeline(this.computePipeline),i.setBindGroup(0,this.computeBindGroup),i.dispatchWorkgroups(Math.ceil(this.cellCount/256)),i.end()}var i=t.beginComputePass();i.setPipeline(this.countPipeline),i.setBindGroup(0,this.countBindGroup),i.dispatchWorkgroups(Math.ceil(this.cellCount/256)),i.end(),10===this.i&&(this.readBack(),this.i=0),'
$mainCoreNew = 'var t=this.device.createCommandEncoder();t.clearBuffer(this.activeCountBuffer),t.clearBuffer(this.totalCountBuffer),t.clearBuffer(this.gwCount);var n=t.beginComputePass();n.setPipeline(this.deletePipeline),n.setBindGroup(0,this.deleteBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();this.device.queue.submit([t.finish()]);for(var r=0;r<50;r++){this.flushParticleSpawns();var t=this.device.createCommandEncoder();var n=t.beginComputePass();n.setPipeline(this.computePipeline),n.setBindGroup(0,this.computeBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();this.device.queue.submit([t.finish()])}var t=this.device.createCommandEncoder();var i=t.beginComputePass();i.setPipeline(this.countPipeline),i.setBindGroup(0,this.countBindGroup),i.dispatchWorkgroups(Math.ceil(this.cellCount/256)),i.end(),10===this.i&&(this.readBack(),this.i=0),'
$source = Replace-Once $source $mainCoreOld $mainCoreNew 'interleaved main simulation'

[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))
$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Patched extractor queue: $bundle"
Write-Output "Backup SHA256: $backupHash"
Write-Output "Patched SHA256: $newHash"
