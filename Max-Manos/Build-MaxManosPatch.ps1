[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseData,
    [Parameter(Mandatory)][string]$UndertaleModCli,
    [Parameter(Mandatory)][string]$Output
)

$ErrorActionPreference = 'Stop'
$base = (Get-Item -LiteralPath $BaseData).FullName
$cli = Get-Item -LiteralPath $UndertaleModCli
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
$stockHash = '2DE3C6077F0447AAB07DC4A0BFE00490D77CA240259D40374AFFCEE24DC3CF9C'
$patchedHash = 'FB5BFD10C996B2548A5082908402ED310A377B71261FD22BF447530B64C3D4F5'

if ($cli.VersionInfo.FileVersion -ne '0.9.2.0') {
    throw 'This build uses UndertaleModCli 0.9.2.0.'
}
if ((Get-FileHash -LiteralPath $base).Hash -ne $stockHash) {
    throw 'The original Max Manos data.win has a different SHA-256.'
}
if (Test-Path -LiteralPath $destination) {
    throw 'Choose a new output file.'
}

$parent = (Get-Item -LiteralPath (Split-Path -Parent $destination)).FullName
$temporary = Join-Path $parent ('max-manos-' + [guid]::NewGuid().ToString('N') + '.win')
try {
    Push-Location -LiteralPath $PSScriptRoot
    try {
        & $cli.FullName load $base --scripts (Join-Path $PSScriptRoot 'work/patch_draw.csx') --output $temporary
        if ($LASTEXITCODE -ne 0) { throw 'UndertaleModCli could not build the patch.' }
    } finally {
        Pop-Location
    }
    if ((Get-FileHash -LiteralPath $temporary).Hash -ne $patchedHash) {
        throw 'The rebuilt data.win differs from the verified experimental patch.'
    }
    [IO.File]::Move($temporary, $destination)
    Get-FileHash -LiteralPath $destination
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
