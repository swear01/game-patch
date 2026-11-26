param([switch]$Test)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source = Join-Path $PSScriptRoot 'openspeedy-guard.cs'
$binary = Join-Path $PSScriptRoot 'openspeedy-guard.exe'
& $compiler /nologo /platform:x64 /optimize+ /target:exe /reference:System.Web.Extensions.dll "/out:$binary" $source
if ($LASTEXITCODE -ne 0) { throw 'Clock isolation helper compilation failed' }
if ($Test) {
    & $binary --self-test
    if ($LASTEXITCODE -ne 0) { throw 'Clock isolation helper self-test failed' }
}
Get-FileHash -LiteralPath $binary -Algorithm SHA256
