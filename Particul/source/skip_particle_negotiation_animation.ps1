param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$expectedHash = '1BFB95C0FC214BB922C4F91858A560983D0C30A78736762F6B3F35F36507BE85'
$backup = "$bundle.before-negotiate-skip-20260904.js"

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
$old = 'A.current=new ai(u.current,e,function(e){var t=e.slice(0,12).reduce(function(e,t){return e+t},0),n=ci[Math.abs(6-t)];s(n),setTimeout(function(){i.onFinish(n),.5===n&&window.electron.activateAchievement("just-skill"),o()},1500)})'
$new = 'var t=e.slice(0,12).reduce(function(e,t){return e+t},0),n=ci[Math.abs(6-t)];s(n),i.onFinish(n),.5===n&&window.electron.activateAchievement("just-skill"),o()'
$source = Replace-Once $source $old $new 'skip negotiation animation'
[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))

$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Skipped Plinko negotiation animation and applied result immediately: $bundle"
Write-Output "Backup: $backup"
Write-Output "Patched SHA256: $newHash"
