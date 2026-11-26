param([string]$Label = 'achievement-live')
$ErrorActionPreference='Stop'
$game=Join-Path $PSScriptRoot 'game-achievement-clock'
if (Get-Process outhold_windows,outhold_native_play -ErrorAction SilentlyContinue) { throw 'Outhold already has the original save open' }
$launch=@{
 FilePath=Join-Path $game 'outhold_native_play.exe'
 WorkingDirectory=$game
 ArgumentList=@('--windowed','--resolution','1280x720','--disable-vsync','--max-fps','120')
 Environment=@{OUTHOLD_ACHIEVEMENT_PLAN=(Join-Path $PSScriptRoot 'achievement-plan.json')}
 WindowStyle='Normal'
 RedirectStandardOutput=Join-Path $PSScriptRoot "$Label.out"
 RedirectStandardError=Join-Path $PSScriptRoot "$Label.err"
 PassThru=$true
}
Start-Process @launch
