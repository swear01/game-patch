#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$GameDirectory,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [string]$StockExecutable,
    [string]$Dumpbin
)

$ErrorActionPreference = 'Stop'
$node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
$game = (Resolve-Path -LiteralPath $GameDirectory).ProviderPath
$data = Join-Path $game 'data.win'
if (!$StockExecutable) { $StockExecutable = Join-Path $game 'Shelldiver.exe' }
$exe = (Resolve-Path -LiteralPath $StockExecutable).ProviderPath
if (!$Dumpbin) {
    $Dumpbin = (Get-Command dumpbin.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (!$Dumpbin) { throw 'Run in a Visual Studio Developer PowerShell or pass the path to Microsoft dumpbin.exe.' }
}
$Dumpbin = (Resolve-Path -LiteralPath $Dumpbin).ProviderPath

$expectedData = '4B4F08B6C85FD3852A08BCCDBB0D6621CC614225F9F804DF6AFE79258E8C0506'
$expectedExe = '62599F01A4CE4B8946FCC38827E6364539E31ABBED99B0828112E670B0C3925E'
if ((Get-FileHash -LiteralPath $data).Hash -ne $expectedData) {
    throw 'The input data.win does not match the supported original Steam build.'
}
if ((Get-FileHash -LiteralPath $exe).Hash -ne $expectedExe) {
    throw 'The executable is not the supported original Shelldiver.exe. Supply an unpatched local executable with -StockExecutable.'
}

$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$null = [IO.Directory]::CreateDirectory($out)
$terrain = Join-Path $out 'ShelldiverTerrain.original.json'
$layout = Join-Path $out 'skill-layout.original.json'
$prices = Join-Path $out 'skill-prices.original.json'

& $node (Join-Path $PSScriptRoot 'Export-ShelldiverTerrain.mjs') $data $terrain
if ($LASTEXITCODE -ne 0) { throw 'Original terrain extraction failed.' }
& $node (Join-Path $PSScriptRoot 'Export-ShelldiverSkillLayout.mjs') $data $layout
if ($LASTEXITCODE -ne 0) { throw 'Original skill layout extraction failed.' }
& $node (Join-Path $PSScriptRoot 'Export-ShelldiverSkillPrices.mjs') $exe $layout $Dumpbin $prices
if ($LASTEXITCODE -ne 0) { throw 'Original skill price extraction failed.' }

$expected = [ordered]@{
    $terrain = 'EFAC0B0CC223B1DA188481F8DCF22A396B5EC0BB29F6CF6A4A145A2F86D53460'
    $layout = '2D9D409635C101D1A36B5702F2DB675895F2A282F2E51FD0EFB319FBCC7AB987'
    $prices = '94FF41A9B7E4A8D1C1C44A4829CF5BFC08F6677726A483E1D092B868FDB9EA89'
}
foreach ($path in $expected.Keys) {
    $actual = (Get-FileHash -LiteralPath $path).Hash
    if ($actual -ne $expected[$path]) { throw "Generated metadata hash did not match for $path." }
    [pscustomobject]@{ Path = $path; Sha256 = $actual }
}
