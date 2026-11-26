param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$backup = "$bundle.before-count-readback-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
if (-not (Test-Path -LiteralPath $backup)) { throw "Backup not found: $backup" }

$sourceHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
$backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
if ($sourceHash -ne $backupHash) {
    throw 'The renderer bundle no longer matches the count-readback backup; refusing to overwrite an unexpected change.'
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "${Label}: expected 1 match, found $count" }
    return $Text.Replace($Old, $New)
}

$source = [IO.File]::ReadAllText($bundle)
$frameStart = $source.IndexOf('key:"frame",value:function(){if(!this.paused)', [StringComparison]::Ordinal)
if ($frameStart -lt 0) { throw 'Main frame method not found' }
$frameEnd = $source.IndexOf('},{key:', $frameStart + 10, [StringComparison]::Ordinal)
if ($frameEnd -lt 0) { throw 'Main frame method end not found' }
$frame = $source.Substring($frameStart, $frameEnd - $frameStart)

# Count/readback must run after the final count pass has been submitted.
$frame = Replace-Once $frame 'i.end(),10===this.i&&(this.readBack(),this.i=0),this.device.queue.writeBuffer' 'i.end(),this.device.queue.writeBuffer' 'pre-submit readback'
$frame = Replace-Once $frame 'this.device.queue.submit([t.finish()]),this.pendingDeleteClear' 'this.device.queue.submit([t.finish()]),10===this.i&&(this.readBack(),this.i=0),this.pendingDeleteClear' 'post-submit readback'
$source = $source.Substring(0, $frameStart) + $frame + $source.Substring($frameEnd)

[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))
$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Fixed count readback: $bundle"
Write-Output "Backup SHA256: $backupHash"
Write-Output "Patched SHA256: $newHash"
