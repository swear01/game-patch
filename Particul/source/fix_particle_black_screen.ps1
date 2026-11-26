param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$backup = "$bundle.before-black-screen-repair-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
if (-not (Test-Path -LiteralPath $backup)) { throw "Backup not found: $backup" }

$sourceHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
$backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
if ($sourceHash -ne $backupHash) {
    throw 'The renderer bundle no longer matches the black-screen backup; refusing to overwrite an unexpected change.'
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "${Label}: expected 1 match, found $count" }
    return $Text.Replace($Old, $New)
}

$source = [IO.File]::ReadAllText($bundle)

# Do not let one extractor accumulate an unbounded queue of duplicate writes.
$source = Replace-Once $source 'key:"queueParticleAt",value:function(e,t,n,r){this.pendingSpawns.push([e,t,n,!!r])}' 'key:"queueParticleAt",value:function(e,t,n,r){var i=e+":"+t;this.pendingSpawns.some(function(e){return e[0]+":"+e[1]===i})||this.pendingSpawns.push([e,t,n,!!r])}' 'bounded extractor queue'

# Keep the 50 particle steps but use one command buffer/submit per frame.
$oldCore = 'var t=this.device.createCommandEncoder();t.clearBuffer(this.activeCountBuffer),t.clearBuffer(this.totalCountBuffer),t.clearBuffer(this.gwCount);var n=t.beginComputePass();n.setPipeline(this.deletePipeline),n.setBindGroup(0,this.deleteBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();this.device.queue.submit([t.finish()]);for(var r=0;r<50;r++){this.flushParticleSpawns();var t=this.device.createCommandEncoder();var n=t.beginComputePass();n.setPipeline(this.computePipeline),n.setBindGroup(0,this.computeBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();this.device.queue.submit([t.finish()])}var t=this.device.createCommandEncoder();var i=t.beginComputePass();i.setPipeline(this.countPipeline),i.setBindGroup(0,this.countBindGroup),i.dispatchWorkgroups(Math.ceil(this.cellCount/256)),i.end(),this.device.queue.writeBuffer(this.frameUniformBuffer'
$newCore = 'var t=this.device.createCommandEncoder();t.clearBuffer(this.activeCountBuffer),t.clearBuffer(this.totalCountBuffer),t.clearBuffer(this.gwCount);var n=t.beginComputePass();n.setPipeline(this.deletePipeline),n.setBindGroup(0,this.deleteBindGroup),n.dispatchWorkgroups(Math.ceil(this.cellCount/256)),n.end();this.flushParticleSpawns();for(var r=0;r<50;r++){var i=t.beginComputePass();i.setPipeline(this.computePipeline),i.setBindGroup(0,this.computeBindGroup),i.dispatchWorkgroups(Math.ceil(this.cellCount/256)),i.end()}var i=t.beginComputePass();i.setPipeline(this.countPipeline),i.setBindGroup(0,this.countBindGroup),i.dispatchWorkgroups(Math.ceil(this.cellCount/256)),i.end(),this.device.queue.writeBuffer(this.frameUniformBuffer'
$source = Replace-Once $source $oldCore $newCore 'single-submit main frame'

[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))
$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Repaired black-screen queue: $bundle"
Write-Output "Backup SHA256: $backupHash"
Write-Output "Patched SHA256: $newHash"
