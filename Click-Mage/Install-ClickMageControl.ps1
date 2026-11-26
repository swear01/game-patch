param(
    [ValidateSet('Install', 'Restore')]
    [string]$Action = 'Install',
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'
$gameRoot = (Get-Item -LiteralPath $GameDirectory).FullName
$managed = Join-Path $gameRoot 'ClickMage_Data\Managed'
$gameAssembly = Join-Path $managed '_GameAssembly.dll'
$originalHash = 'F44D8FD3A0BEF0524B73BF40CB14F3EBA02A0252836EBA27D628B2AC41EEDBFD'
$backup = "$gameAssembly.clickmage-control-original"
$gameExe = Join-Path $gameRoot 'ClickMage.exe'
$running = Get-Process -Name 'ClickMage' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $gameExe }
if ($running) { throw 'Close Click Mage before changing the installation.' }

$tempRoot = (Get-Item -LiteralPath $env:TEMP).FullName
$build = Join-Path $tempRoot ('ClickMageControlBuild-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $build | Out-Null
try {
    $dotnet = (Get-Command dotnet -CommandType Application | Select-Object -First 1).Source
    $project = Join-Path $PSScriptRoot 'PatchClickMage.csproj'
    & $dotnet build $project --configuration Release --artifacts-path $build --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Click Mage patcher build failed.' }

    $patcher = Join-Path $build 'bin\PatchClickMage\release\PatchClickMage.dll'
    if ($Action -eq 'Restore') {
        & $dotnet $patcher restore $managed
        if ($LASTEXITCODE -ne 0) { throw 'Click Mage restoration failed.' }
        return
    }

    $original = if (Test-Path -LiteralPath $backup) { $backup } else { $gameAssembly }
    if ((Get-FileHash -LiteralPath $original).Hash -ne $originalHash) {
        throw 'A supported original Click Mage assembly is required to compile the control bridge.'
    }

    $sdkRoot = Join-Path (Split-Path -Parent $dotnet) 'sdk'
    $compiler = Get-ChildItem -LiteralPath $sdkRoot -Directory |
        Sort-Object -Property { $_.Name.Split('-')[0] -as [version] } -Descending |
        ForEach-Object { Join-Path $_.FullName 'Roslyn\bincore\csc.dll' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $compiler) { throw 'A .NET SDK with the Roslyn compiler is required.' }

    $helper = Join-Path $build 'ClickMageControl.dll'
    $sources = 'ClickMageControl.cs', 'ClickMageProgression.cs', 'ClickMageEnding.cs', 'ClickMageTransfer.cs' |
        ForEach-Object { Join-Path $PSScriptRoot $_ }
    $references = @('mscorlib.dll', 'netstandard.dll', 'System.dll', 'System.Core.dll', 'UnityEngine.CoreModule.dll',
        'UnityEngine.Physics2DModule.dll', 'UnityEngine.UIModule.dll', 'Unity.InputSystem.dll',
        'UnityEngine.InputLegacyModule.dll', 'MoreMountains.Tools.dll', 'Newtonsoft.Json.dll',
        'UnityEngine.UI.dll', 'DialogueSystem.dll', 'PixelCrushers.dll') |
        ForEach-Object { '/reference:' + (Join-Path $managed $_) }
    & $dotnet exec $compiler /nologo /noconfig /nostdlib /target:library /optimize+ /deterministic "/out:$helper" "/reference:$original" @references @sources
    if ($LASTEXITCODE -ne 0) { throw 'Click Mage control bridge compilation failed.' }

    & $dotnet $patcher install $managed $helper
    if ($LASTEXITCODE -ne 0) { throw 'Click Mage control installation failed.' }
} finally {
    $target = Get-Item -LiteralPath $build -ErrorAction SilentlyContinue
    if ($target -and $target.Parent.FullName -eq $tempRoot -and $target.Name -like 'ClickMageControlBuild-*') {
        Remove-Item -LiteralPath $target.FullName -Recurse -Force
    }
}
