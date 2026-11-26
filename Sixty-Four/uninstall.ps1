#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$record = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installation.json') -Raw | ConvertFrom-Json
$gameDir = [IO.Path]::GetFullPath($record.gameDir)
$gameExe = Join-Path $gameDir 'sixtyfour.exe'
if (Get-Process sixtyfour -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $gameExe }) { throw 'Save and quit Sixty Four from its in-game menu first.' }
$appRoot = [IO.Path]::GetFullPath((Join-Path $gameDir 'resources/app'))
$bridgeDir = [IO.Path]::GetFullPath((Join-Path $appRoot 'agent-bridge'))
if ($bridgeDir -ne ($appRoot + [IO.Path]::DirectorySeparatorChar + 'agent-bridge')) { throw 'Unexpected bridge directory.' }
$ownedFiles = @('bridge-main.cjs','bridge-gateway.cjs','renderer-adapter.cjs','audio-guard.cjs','bridge-config.json','bridge.log','simulation-clock.cjs','speed-control.cjs','openspeedy-guard.exe')
if (Test-Path -LiteralPath $bridgeDir) {
    if ((Get-Item -LiteralPath $bridgeDir).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The bridge directory is a link. Preserve it and inspect before uninstalling.' }
    $unknown = Get-ChildItem -LiteralPath $bridgeDir -Force | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -notin $ownedFiles }
    if ($unknown) { throw 'The bridge contains unrecognized files. Preserve them and inspect before uninstalling.' }
}
$mainPath = Join-Path $gameDir 'resources/app/main.js'
$backupPath = Join-Path $record.backupDir 'main.js.original'
$mainHash = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
if ($mainHash -ne $record.installedHash -and $mainHash -ne $record.originalHash) { throw 'main.js changed after installation. Preserve it and merge the removal manually.' }
if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -ne $record.originalHash) { throw 'Original backup failed hash verification.' }
if ($record.freezeFix) {
    $expectedScript = [IO.Path]::GetFullPath((Join-Path $gameDir 'resources/app/game/scripts/game.js'))
    if ([IO.Path]::GetFullPath($record.freezeFix.path) -ne $expectedScript) { throw 'Unexpected clock fix target.' }
    $gameHash = (Get-FileHash -LiteralPath $expectedScript -Algorithm SHA256).Hash
    if ($gameHash -ne $record.freezeFix.installedHash -and $gameHash -ne $record.freezeFix.originalHash) { throw 'game.js changed after installation. Preserve it and inspect before restoring.' }
    if ((Get-FileHash -LiteralPath $record.freezeFix.backupPath -Algorithm SHA256).Hash -ne $record.freezeFix.originalHash) { throw 'Original game.js backup failed verification.' }
}
if ($mainHash -ne $record.originalHash) { Copy-Item -LiteralPath $backupPath -Destination $mainPath }
if ($record.freezeFix -and $gameHash -ne $record.freezeFix.originalHash) { Copy-Item -LiteralPath $record.freezeFix.backupPath -Destination $expectedScript }
if (Test-Path -LiteralPath $bridgeDir) { Remove-Item -LiteralPath $bridgeDir -Recurse -Force }
Write-Output 'Original game files restored and bridge removed. Save progress and backups retained.'
