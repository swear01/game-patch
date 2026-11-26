param(
    [ValidateSet('install', 'restore')]
    [string]$Action = 'install',
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'
$managed = Join-Path $GameDirectory 'Cypher_Data\Managed'
$settings = Join-Path $GameDirectory 'Cypher_Data\globalgamemanagers'
$settingsBackup = "$settings.cypher-assist-original"
$originalSettingsHash = '72F723F65A2897823EC65EF95CD21ACFC577BAE0923C7D2603F9164A1E4D372B'
$legacyWindowedSettingsHash = '37E0B59E9AC6E573350E59D269F4B27D707236C5EEF316CEAF1385031F3BF09E'
$borderlessSettingsHash = 'BE4D84B83ADB7D367599BA8DA9DDB849E8D8A504C2BF6E3DA3B5998F680EFC58'
$build = Join-Path $env:LOCALAPPDATA 'CypherAssistBuild\artifacts'
$project = Join-Path $PSScriptRoot 'PatchCypher.csproj'

$settingsHash = (Get-FileHash -LiteralPath $settings).Hash
if ($settingsHash -notin @($originalSettingsHash, $legacyWindowedSettingsHash, $borderlessSettingsHash)) {
    throw 'Cypher display settings do not match the supported build.'
}
$hasOriginalSettings = $settingsHash -eq $originalSettingsHash
if (-not $hasOriginalSettings -and (Get-FileHash -LiteralPath $settingsBackup).Hash -ne $originalSettingsHash) {
    throw 'Cypher display settings backup does not match the original.'
}

dotnet build $project --configuration Release --artifacts-path $build --nologo
if ($LASTEXITCODE -ne 0) { throw 'Cypher patcher build failed.' }

$patcher = Join-Path $build 'bin\PatchCypher\release\PatchCypher.dll'
if ($Action -eq 'restore') {
    dotnet $patcher restore $managed
    if ($LASTEXITCODE -ne 0) { throw 'Could not restore Cypher.' }
    if (-not $hasOriginalSettings) {
        [IO.File]::Replace($settingsBackup, $settings, [NullString]::Value)
        Write-Output 'Restored the original display settings.'
    }
    return
}

$dotnetRoot = Split-Path -Parent (Get-Command dotnet -CommandType Application | Select-Object -First 1 -ExpandProperty Source)
$compiler = Get-ChildItem -LiteralPath (Join-Path $dotnetRoot 'sdk') -Directory |
    Sort-Object -Property Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'Roslyn\bincore\csc.dll' } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $compiler) { throw 'A .NET SDK with the Roslyn compiler is required.' }

$assist = Join-Path $build 'CypherAssist.dll'
$references = @('mscorlib.dll', 'System.dll', 'UnityEngine.dll', 'UnityEngine.UI.dll', 'TextMeshPro-1.0.55.56.0b11.dll') |
    ForEach-Object { '/reference:' + (Join-Path $managed $_) }
dotnet exec $compiler /nologo /noconfig /nostdlib /target:library /optimize+ /deterministic "/out:$assist" @references (Join-Path $PSScriptRoot 'CypherAssist.cs')
if ($LASTEXITCODE -ne 0) { throw 'Cypher Assist compilation failed.' }

dotnet $patcher install $managed $assist
if ($LASTEXITCODE -ne 0) { throw 'Could not install Cypher Assist.' }

if ($settingsHash -ne $borderlessSettingsHash) {
    $originalSettings = if ($hasOriginalSettings) { $settings } else { $settingsBackup }
    $bytes = [IO.File]::ReadAllBytes($originalSettings)
    # Keep Cypher's native-resolution D3D11 fullscreen window and skip the resolution dialog.
    [BitConverter]::GetBytes([uint32]0).CopyTo($bytes, 4392)
    $bytes[4455] = 1 # Keep the fullscreen window visible in the background.
    $temporary = "$settings.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $bytes)
        if ((Get-FileHash -LiteralPath $temporary).Hash -ne $borderlessSettingsHash) {
            throw 'Could not verify the borderless display settings.'
        }
        if ($hasOriginalSettings) {
            [IO.File]::Replace($temporary, $settings, $settingsBackup)
        } else {
            [IO.File]::Replace($temporary, $settings, [NullString]::Value)
        }
        Write-Output 'Set the default display to a borderless window at native resolution.'
    } finally {
        [IO.File]::Delete($temporary)
    }
}
