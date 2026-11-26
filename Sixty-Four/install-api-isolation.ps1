#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$EnableSpeedControl,
    [string]$OpenSpeedyDir = (Join-Path $env:ProgramFiles 'OpenSpeedy')
)
$ErrorActionPreference = 'Stop'
$recordPath = Join-Path $PSScriptRoot 'installation.json'
$cliConfigPath = Join-Path $PSScriptRoot 'bridge-config.json'
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$gameDir = [IO.Path]::GetFullPath($record.gameDir)
$gameExe = Join-Path $gameDir 'sixtyfour.exe'
if (Get-Process sixtyfour -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $gameExe }) { throw 'Save and quit Sixty Four before upgrading API isolation.' }
$appDir = Join-Path $gameDir 'resources/app'
$mainPath = Join-Path $appDir 'main.js'
if ((Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash -ne $record.installedHash) { throw 'main.js no longer matches the installed hook. Inspect before upgrading.' }
if ($record.apiIsolation -and $record.apiIsolation.version -ne 1) { throw 'Unsupported API isolation installation record.' }
$bridgeDir = [IO.Path]::GetFullPath((Join-Path $appDir 'agent-bridge'))
if (!(Test-Path -LiteralPath $bridgeDir -PathType Container) -or ((Get-Item -LiteralPath $bridgeDir).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The installed bridge must be a regular directory.' }
$ownedFiles = @('bridge-main.cjs','bridge-gateway.cjs','renderer-adapter.cjs','audio-guard.cjs','bridge-config.json','bridge.log','simulation-clock.cjs','speed-control.cjs','openspeedy-guard.exe')
if (Get-ChildItem -LiteralPath $bridgeDir -Force | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -notin $ownedFiles }) { throw 'The bridge contains unrecognized files. Preserve them and inspect before upgrading.' }
$nodePath = [IO.Path]::GetFullPath((Get-Command node -CommandType Application | Select-Object -First 1).Source)
$nodeCheck = & $nodePath -p "Number(process.versions.node.split('.')[0]) >= 24 && !process.versions.electron && process.release.name === 'node' ? 'standalone-node-ok' : 'unsupported'"
if ($LASTEXITCODE -ne 0 -or $nodeCheck -ne 'standalone-node-ok') { throw 'Standalone Node.js 24 or newer is required.' }
$installedConfigPath = Join-Path $bridgeDir 'bridge-config.json'
$cliConfig = Get-Content -LiteralPath $cliConfigPath -Raw | ConvertFrom-Json
$installedConfig = Get-Content -LiteralPath $installedConfigPath -Raw | ConvertFrom-Json
foreach ($field in @('url','port','token')) {
    if ($null -eq $cliConfig.$field -or $cliConfig.$field -cne $installedConfig.$field) { throw 'Installed and CLI configuration disagree. Inspect before upgrading.' }
}
$replacementFiles = @('bridge-main.cjs','bridge-gateway.cjs','renderer-adapter.cjs','audio-guard.cjs')
$speedControlEnabled = $EnableSpeedControl -or $installedConfig.speedControl.enabled -eq $true -or $cliConfig.speedControl.enabled -eq $true
$speedControl = $null
$dllHash = $null
if ($speedControlEnabled) {
    if (!(Test-Path -LiteralPath $gameExe -PathType Leaf)) { throw 'The game executable is missing.' }
    $dllPath = [IO.Path]::GetFullPath((Join-Path $OpenSpeedyDir 'speedpatch64.dll'))
    if (!$PSBoundParameters.ContainsKey('OpenSpeedyDir') -and $installedConfig.speedControl.dllPath) { $dllPath = [IO.Path]::GetFullPath($installedConfig.speedControl.dllPath) }
    if (!(Test-Path -LiteralPath $dllPath -PathType Leaf) -and !$PSBoundParameters.ContainsKey('OpenSpeedyDir')) {
        $speedyCommand = Get-Command openspeedy -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($speedyCommand) { $dllPath = Join-Path (Split-Path $speedyCommand.Source -Parent) 'speedpatch64.dll' }
    }
    if (!(Test-Path -LiteralPath $dllPath -PathType Leaf)) { throw 'OpenSpeedy speedpatch64.dll was not found. Specify -OpenSpeedyDir.' }
    $dllHash = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash
    if ($dllHash -ne 'c72ba4d9e35c5c00efc113e541da91a02dbc0c85c6fb2effff5cee63898bc70c') { throw 'Unsupported OpenSpeedy speedpatch64.dll hash. No game files were changed.' }
    $replacementFiles += @('simulation-clock.cjs','speed-control.cjs','openspeedy-guard.exe')
    $speedControl = @{ enabled=$true; gameExe=$gameExe; dllPath=[IO.Path]::GetFullPath($dllPath); helperPath=(Join-Path $bridgeDir 'openspeedy-guard.exe') }
}
foreach ($file in $replacementFiles) {
    if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) { throw "Missing package file: $file" }
    if ($file.EndsWith('.cjs')) {
        & $nodePath --check (Join-Path $PSScriptRoot $file)
        if ($LASTEXITCODE -ne 0) { throw "Invalid JavaScript: $file" }
    }
}
# Check all existing targets before changing any installed file.
foreach ($target in (@($recordPath, $cliConfigPath, $installedConfigPath) + @($replacementFiles | ForEach-Object { Join-Path $bridgeDir $_ }))) {
    if (Test-Path -LiteralPath $target) {
        $probe = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $probe.Dispose()
    }
}
$backupDir = Join-Path $PSScriptRoot ('backups/api-isolation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backupDir | Out-Null
Copy-Item -LiteralPath $bridgeDir -Destination (Join-Path $backupDir 'agent-bridge') -Recurse
Copy-Item -LiteralPath $recordPath -Destination (Join-Path $backupDir 'installation.json')
Copy-Item -LiteralPath $cliConfigPath -Destination (Join-Path $backupDir 'bridge-config.json')
$stageDir = Join-Path $backupDir 'staged'
New-Item -ItemType Directory -Path $stageDir | Out-Null
foreach ($file in $replacementFiles) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $stageDir $file) }
$cliConfig | Add-Member -NotePropertyName nodePath -NotePropertyValue $nodePath -Force
$installedConfig | Add-Member -NotePropertyName nodePath -NotePropertyValue $nodePath -Force
if ($speedControl) {
    $cliConfig | Add-Member -NotePropertyName speedControl -NotePropertyValue $speedControl -Force
    $installedConfig | Add-Member -NotePropertyName speedControl -NotePropertyValue $speedControl -Force
}
[IO.File]::WriteAllText((Join-Path $stageDir 'cli-config.json'), ($cliConfig | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $stageDir 'installed-config.json'), ($installedConfig | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$hashes = @{}
foreach ($file in $replacementFiles) { $hashes[$file] = (Get-FileHash -LiteralPath (Join-Path $stageDir $file) -Algorithm SHA256).Hash }
$apiIsolation = @{ version=1; nodePath=$nodePath; backupDir=$backupDir; files=$hashes }
if ($speedControl) { $apiIsolation.speedControlDllHash = $dllHash }
$record | Add-Member -NotePropertyName apiIsolation -NotePropertyValue $apiIsolation -Force
[IO.File]::WriteAllText((Join-Path $stageDir 'installation.json'), ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

function Set-AtomicFile([string]$Source, [string]$Target) {
    $temporary = $Target + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::Copy($Source, $temporary)
        [IO.File]::Move($temporary, $Target, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
$changes = [Collections.Generic.List[object]]::new()
try {
    foreach ($file in $replacementFiles) {
        $target = Join-Path $bridgeDir $file
        $original = Join-Path (Join-Path $backupDir 'agent-bridge') $file
        Set-AtomicFile (Join-Path $stageDir $file) $target
        $changes.Add(@{ target=$target; original=$original })
    }
    foreach ($item in @(
        @{ source='installed-config.json'; target=$installedConfigPath; original=(Join-Path (Join-Path $backupDir 'agent-bridge') 'bridge-config.json') },
        @{ source='cli-config.json'; target=$cliConfigPath; original=(Join-Path $backupDir 'bridge-config.json') },
        @{ source='installation.json'; target=$recordPath; original=(Join-Path $backupDir 'installation.json') }
    )) {
        Set-AtomicFile (Join-Path $stageDir $item.source) $item.target
        $changes.Add(@{ target=$item.target; original=$item.original })
    }
} catch {
    $failure = $_
    $rollbackFailures = [Collections.Generic.List[string]]::new()
    for ($i = $changes.Count - 1; $i -ge 0; $i--) {
        $item = $changes[$i]
        try {
            if (Test-Path -LiteralPath $item.original) { Set-AtomicFile $item.original $item.target }
            elseif (Test-Path -LiteralPath $item.target) { Remove-Item -LiteralPath $item.target }
        } catch { $rollbackFailures.Add($item.target) }
    }
    if ($rollbackFailures.Count) { throw "API upgrade failed and rollback could not restore $($rollbackFailures.Count) file(s). Preserve backup: $backupDir" }
    throw $failure
}
Write-Output "API isolation installed. Full previous bridge and configuration backup: $backupDir"
Write-Output 'Launch Sixty Four normally through Steam. The port and token are unchanged.'
