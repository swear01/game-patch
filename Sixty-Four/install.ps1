#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GameDir,
    [ValidateRange(1024,65535)][int]$Port = 6464,
    [switch]$EnableSpeedControl,
    [string]$OpenSpeedyDir = (Join-Path $env:ProgramFiles 'OpenSpeedy')
)
$ErrorActionPreference = 'Stop'
$nodePath = [IO.Path]::GetFullPath((Get-Command node -CommandType Application | Select-Object -First 1).Source)
$nodeCheck = & $nodePath -p "Number(process.versions.node.split('.')[0]) >= 24 && !process.versions.electron && process.release.name === 'node' ? 'standalone-node-ok' : 'unsupported'"
if ($LASTEXITCODE -ne 0 -or $nodeCheck -ne 'standalone-node-ok') { throw 'Standalone Node.js 24 or newer is required.' }
foreach ($file in @('bridge-main.cjs','bridge-gateway.cjs','renderer-adapter.cjs','audio-guard.cjs','clock-fix.cjs')) {
    if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) { throw "Missing package file: $file" }
}
$appDir = Join-Path ([IO.Path]::GetFullPath($GameDir)) 'resources/app'
$mainPath = Join-Path $appDir 'main.js'
if (!(Test-Path -LiteralPath $mainPath)) { throw 'GameDir must contain resources/app/main.js (the win-unpacked directory).' }
$gameExe = Join-Path ([IO.Path]::GetFullPath($GameDir)) 'sixtyfour.exe'
if (Get-Process sixtyfour -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $gameExe }) { throw 'Save and quit Sixty Four from its in-game menu before installing.' }
$marker = '// SIXTYFOUR_AGENT_BRIDGE_V1'
$source = [IO.File]::ReadAllText($mainPath)
$bridgeDir = Join-Path $appDir 'agent-bridge'
$runtimeFiles = @('bridge-main.cjs','bridge-gateway.cjs','renderer-adapter.cjs','audio-guard.cjs')
$speedControl = $null
$dllHash = $null
if ($EnableSpeedControl) {
    if (!(Test-Path -LiteralPath $gameExe -PathType Leaf)) { throw 'The game executable is missing.' }
    $dllPath = [IO.Path]::GetFullPath((Join-Path $OpenSpeedyDir 'speedpatch64.dll'))
    if (!(Test-Path -LiteralPath $dllPath -PathType Leaf) -and !$PSBoundParameters.ContainsKey('OpenSpeedyDir')) {
        $speedyCommand = Get-Command openspeedy -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($speedyCommand) { $dllPath = Join-Path (Split-Path $speedyCommand.Source -Parent) 'speedpatch64.dll' }
    }
    if (!(Test-Path -LiteralPath $dllPath -PathType Leaf)) { throw 'OpenSpeedy speedpatch64.dll was not found. Specify -OpenSpeedyDir.' }
    $dllHash = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash
    if ($dllHash -ne 'c72ba4d9e35c5c00efc113e541da91a02dbc0c85c6fb2effff5cee63898bc70c') { throw 'Unsupported OpenSpeedy speedpatch64.dll hash. No game files were changed.' }
    $runtimeFiles += @('simulation-clock.cjs','speed-control.cjs','openspeedy-guard.exe')
    $speedControl = @{ enabled=$true; gameExe=$gameExe; dllPath=[IO.Path]::GetFullPath($dllPath); helperPath=(Join-Path $bridgeDir 'openspeedy-guard.exe') }
}
$runtimeHashes = @{}
foreach ($file in $runtimeFiles) {
    $runtimeSource = Join-Path $PSScriptRoot $file
    if (!(Test-Path -LiteralPath $runtimeSource -PathType Leaf)) { throw "Missing package file: $file" }
    if ($file.EndsWith('.cjs')) {
        & $nodePath --check $runtimeSource
        if ($LASTEXITCODE -ne 0) { throw "Invalid JavaScript: $file" }
    }
    $runtimeHashes[$file] = (Get-FileHash -LiteralPath $runtimeSource -Algorithm SHA256).Hash
}
if ($source.Contains($marker)) { throw 'The bridge is already installed. Uninstall before reinstalling.' }
if (Test-Path -LiteralPath $bridgeDir) { throw 'An agent-bridge directory already exists. Preserve it and inspect before installing.' }
if (!(Test-Path -LiteralPath (Join-Path $appDir 'game/scripts/game.js'))) { throw 'Unsupported game layout.' }
$gameScript = Join-Path $appDir 'game/scripts/game.js'
& $nodePath (Join-Path $PSScriptRoot 'clock-fix.cjs') check $gameScript | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unsupported game script for the clock fix.' }
$listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($listener) { throw "Port $Port is already in use." }
$recordPath = Join-Path $PSScriptRoot 'installation.json'
$configPath = Join-Path $PSScriptRoot 'bridge-config.json'
foreach ($existingPath in @($recordPath, $configPath)) {
    if (Test-Path -LiteralPath $existingPath) {
        $probe = [IO.File]::Open($existingPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $probe.Dispose()
    }
}
$previousConfig = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllBytes($configPath) } else { $null }
$backupDir = Join-Path $PSScriptRoot ('backups/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Copy-Item -LiteralPath $mainPath -Destination (Join-Path $backupDir 'main.js.original')
$profileDir = Join-Path $env:APPDATA 'sixtyfour'
if (Test-Path -LiteralPath $profileDir) { Copy-Item -LiteralPath $profileDir -Destination (Join-Path $backupDir 'sixtyfour-profile') -Recurse }
$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$token = [Convert]::ToBase64String($bytes)
$config = @{ url="http://127.0.0.1:$Port"; port=$Port; token=$token; nodePath=$nodePath }
if ($speedControl) { $config.speedControl = $speedControl }
$originalHash = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
# Append bytes so the original file remains byte-for-byte intact before the marker.
$addition = "`r`n$marker`r`nrequire('./agent-bridge/bridge-main.cjs');`r`n"
$appendBytes = [Text.Encoding]::UTF8.GetBytes($addition)
$expectedBytes = [byte[]]([IO.File]::ReadAllBytes($mainPath) + $appendBytes)
$hasher = [Security.Cryptography.SHA256]::Create()
try { $installedHash = [BitConverter]::ToString($hasher.ComputeHash($expectedBytes)).Replace('-', '') } finally { $hasher.Dispose() }
$recordTemp = $recordPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$configTemp = $configPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$freezeFix = $null
$bridgeCreated = $false
$configCommitted = $false
try {
    New-Item -ItemType Directory -Path $bridgeDir | Out-Null
    $bridgeCreated = $true
    foreach ($file in $runtimeFiles) {
        $destination = Join-Path $bridgeDir $file
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $runtimeHashes[$file]) { throw "Package changed during installation: $file" }
    }
    $configText = $config | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $bridgeDir 'bridge-config.json'), $configText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($configTemp, $configText, [Text.UTF8Encoding]::new($false))
    $appendStream = [IO.File]::Open($mainPath, [IO.FileMode]::Append, [IO.FileAccess]::Write)
    try { $appendStream.Write($appendBytes,0,$appendBytes.Length) } finally { $appendStream.Dispose() }
    $freezeFixJson = & $nodePath (Join-Path $PSScriptRoot 'clock-fix.cjs') install $gameScript $backupDir
    if ($LASTEXITCODE -ne 0) { throw 'Clock fix installation failed.' }
    $freezeFix = $freezeFixJson | ConvertFrom-Json
    $apiIsolation = @{ version=1; nodePath=$nodePath; backupDir=$backupDir; files=$runtimeHashes }
    if ($speedControl) { $apiIsolation.speedControlDllHash = $dllHash }
    $record = @{ gameDir=[IO.Path]::GetFullPath($GameDir); backupDir=$backupDir; originalHash=$originalHash; installedHash=$installedHash; freezeFix=$freezeFix; apiIsolation=$apiIsolation }
    [IO.File]::WriteAllText($recordTemp, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($configTemp, $configPath, $true)
    $configCommitted = $true
    [IO.File]::Move($recordTemp, $recordPath, $true)
} catch {
    if ($freezeFix) {
        $gameHash = (Get-FileHash -LiteralPath $gameScript -Algorithm SHA256).Hash
        if ($gameHash -eq $freezeFix.installedHash) {
            if ((Get-FileHash -LiteralPath $freezeFix.backupPath -Algorithm SHA256).Hash -ne $freezeFix.originalHash) { throw 'Installation failed and game.js backup failed verification; preserve backups and inspect manually.' }
            Copy-Item -LiteralPath $freezeFix.backupPath -Destination $gameScript
        } elseif ($gameHash -ne $freezeFix.originalHash) { throw 'Installation failed and game.js changed unexpectedly; preserve backups and inspect manually.' }
    }
    $mainHash = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
    if ($mainHash -eq $installedHash) {
        if ((Get-FileHash -LiteralPath (Join-Path $backupDir 'main.js.original') -Algorithm SHA256).Hash -ne $originalHash) { throw 'Installation failed and main.js backup failed verification; preserve backups and inspect manually.' }
        Copy-Item -LiteralPath (Join-Path $backupDir 'main.js.original') -Destination $mainPath
    } elseif ($mainHash -ne $originalHash) { throw 'Installation failed and main.js changed unexpectedly; preserve backups and inspect manually.' }
    if ($configCommitted) {
        if ($null -ne $previousConfig) { [IO.File]::WriteAllBytes($configPath, [byte[]]$previousConfig) }
        else { Remove-Item -LiteralPath $configPath }
    }
    $resolvedBridge = [IO.Path]::GetFullPath($bridgeDir)
    $expectedBridge = [IO.Path]::GetFullPath((Join-Path $appDir 'agent-bridge'))
    if ($bridgeCreated -and $resolvedBridge -eq $expectedBridge -and (Test-Path -LiteralPath $resolvedBridge)) { Remove-Item -LiteralPath $resolvedBridge -Recurse -Force }
    throw
} finally {
    foreach ($tempPath in @($recordTemp, $configTemp)) { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath } }
}
Write-Output "Installed. Backup: $backupDir"
Write-Output "Launch Sixty Four normally. API: http://127.0.0.1:$Port"
