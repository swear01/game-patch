#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$recordPath = Join-Path $PSScriptRoot 'installation.json'
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$recordProbe = [IO.File]::Open($recordPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
$recordProbe.Dispose()
$gameExe = Join-Path $record.gameDir 'sixtyfour.exe'
if (Get-Process sixtyfour -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $gameExe }) { throw 'Save and quit Sixty Four before installing the clock fix.' }
if ($record.freezeFix) { throw 'The clock fix is already recorded as installed.' }
$gamePath = Join-Path $record.gameDir 'resources/app/game/scripts/game.js'
$backupDir = Join-Path $PSScriptRoot ('backups/clock-fix-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$recordTemp = $recordPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$fix = $null
try {
    $json = & node (Join-Path $PSScriptRoot 'clock-fix.cjs') install $gamePath $backupDir
    if ($LASTEXITCODE -ne 0) { throw 'Clock fix installation failed.' }
    $fix = $json | ConvertFrom-Json
    $record | Add-Member -NotePropertyName freezeFix -NotePropertyValue $fix -Force
    [IO.File]::WriteAllText($recordTemp, ($record | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($recordTemp, $recordPath, $true)
} catch {
    if ($fix) {
        $currentHash = (Get-FileHash -LiteralPath $gamePath -Algorithm SHA256).Hash
        if ($currentHash -eq $fix.installedHash) {
            if ((Get-FileHash -LiteralPath $fix.backupPath -Algorithm SHA256).Hash -ne $fix.originalHash) { throw 'Clock fix installation failed and the original backup failed verification; preserve the backup and inspect manually.' }
            Copy-Item -LiteralPath $fix.backupPath -Destination $gamePath
        } elseif ($currentHash -ne $fix.originalHash) {
            throw 'Clock fix installation failed and game.js changed unexpectedly; preserve the backup and inspect manually.'
        }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $recordTemp) { Remove-Item -LiteralPath $recordTemp }
}
Write-Output "Clock rollback fix installed. Backup: $backupDir"
