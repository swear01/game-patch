param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$expectedHash = '54C580EB82535CF1E609D1997069B6F900229CA87F91F95E22CB735FB568E2A1'
$backup = "$bundle.before-startup-hang-repair-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
$sourceHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
if ($sourceHash -ne $expectedHash) { throw "Unexpected renderer bundle hash: $sourceHash" }
if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $bundle -Destination $backup -Force }

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "${Label}: expected 1 match, found $count" }
    return $Text.Replace($Old, $New)
}

$source = [IO.File]::ReadAllText($bundle)
$source = Replace-Once $source 'case 0:return e.n=1,this.saveDB.tryImportSaveFromCloud();case 1:return e.n=2,this.saveDB.load();' 'case 0:return e.n=1,Promise.resolve();case 1:return e.n=2,this.saveDB.load();' 'skip blocking cloud import during startup'
[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))

$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Bypassed blocking cloud import during startup: $bundle"
Write-Output "Backup: $backup"
Write-Output "Patched SHA256: $newHash"
