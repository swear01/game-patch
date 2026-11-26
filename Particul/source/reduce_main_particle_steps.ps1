param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$backup = "$bundle.before-main-step-5x-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
if (-not (Test-Path -LiteralPath $backup)) { throw "Backup not found: $backup" }

$sourceHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
$backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
if ($sourceHash -ne $backupHash) { throw 'The renderer bundle no longer matches the step-reduction backup.' }

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "${Label}: expected 1 match, found $count" }
    return $Text.Replace($Old, $New)
}

$source = [IO.File]::ReadAllText($bundle)
$source = Replace-Once $source 'for(var r=0;r<50;r++){var i=t.beginComputePass()' 'for(var r=0;r<5;r++){var i=t.beginComputePass()' 'main particle step count'
[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))

$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Reduced main particle steps to 5x: $bundle"
Write-Output "Backup SHA256: $backupHash"
Write-Output "Patched SHA256: $newHash"
