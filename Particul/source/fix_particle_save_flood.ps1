param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$sourceBackup = "$bundle.before-diagnosis-current-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
if (-not (Test-Path -LiteralPath $sourceBackup)) { throw "Preserved current bundle not found: $sourceBackup" }

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "${Label}: expected 1 match, found $count" }
    return $Text.Replace($Old, $New)
}

# Restore the known working accelerated build, then only change autosave cadence.
Copy-Item -LiteralPath $sourceBackup -Destination $bundle -Force
$source = [IO.File]::ReadAllText($bundle)

$source = Replace-Once $source 'this.autoClickers=[],this.autoSellers=[],this.pendingSpawns=[],this.ascensions=[]' 'this.autoClickers=[],this.autoSellers=[],this.pendingSpawns=[],this.lastSaveWallClock=0,this.ascensions=[]' 'save throttle state'
$source = Replace-Once $source 'this.months+=1,this.save(),this.months>=12' 'this.months+=1,performance.now()-this.lastSaveWallClock>=5e3&&(this.lastSaveWallClock=performance.now(),this.save()),this.months>=12' 'throttled autosave'

[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))
$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Throttled accelerated autosave to once per 5 real seconds: $bundle"
Write-Output "Patched SHA256: $newHash"
