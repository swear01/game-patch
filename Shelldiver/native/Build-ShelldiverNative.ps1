#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$YYToolkitSource,

    [Parameter(Mandatory)]
    [string]$JsonHeader,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'build'),

    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'inputs.json') -Raw | ConvertFrom-Json
$compiler = (Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path
if (!$compiler) { throw 'Run this script from an MSVC x64 Developer PowerShell with the Windows SDK installed.' }

$sdk = Join-Path (Resolve-Path -LiteralPath $YYToolkitSource).Path 'ExamplePlugin/include'
foreach ($file in $manifest.dependencies.yytk.sdkFiles.PSObject.Properties) {
    $path = Join-Path $sdk $file.Name
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing pinned YYToolkit SDK file $($file.Name)." }
    $content = [IO.File]::ReadAllText($path).Replace([string][char]13+[char]10,[string][char]10)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content)))
    if ($hash -ne $file.Value) { throw "YYToolkit SDK file $($file.Name) differs from the pinned commit." }
}
$jsonPath = (Resolve-Path -LiteralPath $JsonHeader).Path
if ([IO.Path]::GetFileName($jsonPath) -ne 'json.hpp' -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $jsonPath).Hash -ne $manifest.dependencies.nlohmann.headerSha256) {
    throw 'Use the pinned nlohmann/json 3.12.0 release asset named json.hpp.'
}
$jsonInclude = Split-Path -Parent $jsonPath
$sdkTypes = Join-Path $sdk 'YYToolkit/YYTK_Shared_Types.cpp'
$pluginSource = Join-Path $PSScriptRoot 'src/ShelldiverAutoplay.cpp'
$pluginIncludes = Split-Path -Parent $pluginSource
$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$null = [IO.Directory]::CreateDirectory($out)
$commonArgs = @('/nologo','/std:c++20','/utf-8','/EHsc','/W3','/O2','/MD','/DNOMINMAX',"/I$jsonInclude")
$pluginArgs = @('/LD','/DNDEBUG',"/I$sdk",$pluginSource,$sdkTypes,'/link','/MACHINE:X64',
    '/OUT:ShelldiverAutoplayParticleRenderSuite.dll','user32.lib')

Push-Location -LiteralPath $out
try {
    & $compiler @commonArgs @pluginArgs
    if ($LASTEXITCODE -ne 0) { throw "Shelldiver plugin build failed ($LASTEXITCODE)." }
    $built = Join-Path $out 'ShelldiverAutoplayParticleRenderSuite.dll'
    $installedName = Join-Path $out 'ShelldiverAutoplayNative.dll'
    Copy-Item -LiteralPath $built -Destination $installedName -Force

    if ($SmokeTest) {
        $testSource = Join-Path $PSScriptRoot 'tests/Test-ShelldiverParticleRenderSuite.cpp'
        & $compiler @commonArgs "/I$pluginIncludes" $testSource '/link' '/MACHINE:X64' '/OUT:Test-ShelldiverNative.exe'
        if ($LASTEXITCODE -ne 0) { throw "The isolated smoke test failed to build ($LASTEXITCODE)." }
        & (Join-Path $out 'Test-ShelldiverNative.exe')
        if ($LASTEXITCODE -ne 0) { throw "The isolated smoke test failed ($LASTEXITCODE)." }
    }
    Get-FileHash -Algorithm SHA256 -LiteralPath $installedName
} finally {
    Pop-Location
}
