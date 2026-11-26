param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$expectedHash = 'A4A22444A0E6E75E7E1140D2F21B72793C53C053D16CFEDD482B592761180C88'
$backup = "$bundle.before-slot-price-wheel-skip-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
$sourceHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
if (-not (Test-Path -LiteralPath $backup)) {
    if ($sourceHash -ne $expectedHash) { throw "Unexpected renderer bundle hash: $sourceHash" }
    Copy-Item -LiteralPath $bundle -Destination $backup -Force
} else {
    $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
    if ($backupHash -ne $expectedHash) { throw "Unexpected backup bundle hash: $backupHash" }
    if ($sourceHash -ne $expectedHash) { Copy-Item -LiteralPath $backup -Destination $bundle -Force }
}

$source = [IO.File]::ReadAllText($bundle)

# Slot Machine: keep the same weighted random columns, jackpot re-spin rule,
# result callback, and close action, but do not render or wait for the reels.
$slotStart = $source.IndexOf('B=(0,e.useCallback)(function(){var e=n.rolls,t=n.rollType;', [StringComparison]::Ordinal)
$slotEndMarker = '},[n.types,n.rolls]);return(0,e.useEffect)(function(){B()},[])'
$slotEnd = $source.IndexOf($slotEndMarker, $slotStart, [StringComparison]::Ordinal)
if ($slotStart -lt 0 -or $slotEnd -lt 0) { throw 'Slot Machine callback boundaries not found' }
$slotReplacement = 'B=(0,e.useCallback)(function(){var e=n.rolls,t=n.rollType;for(;;){var r0=new Array(Math.max(1,Math.floor(n.types.length/4))).fill(0).map(function(){return{id:-1,name:"boot"}}),i0=[].concat(Ye(r0),Ye(n.types.reduce(function(e,t){return[].concat(Ye(e),Ye(new Array(Math.max(1,Math.round(n.types.length/t.id))).fill(0).map(function(e){return t})))},[]))),o0=[128*(1+Math.random()*(i0.length-1)*3|0),128*(1+Math.random()*(i0.length-1)*3|0),128*(1+Math.random()*(i0.length-1)*3|0)],a0=[{data:[].concat(Ye($(i0)),Ye($(i0)),Ye($(i0))),offset:o0[0],index:o0[0]/128,roll:e[Math.random()*e.length-1|0]},{data:[].concat(Ye($(i0)),Ye($(i0)),Ye($(i0))),offset:o0[1],index:o0[1]/128,roll:e[Math.random()*e.length-1|0]},{data:[].concat(Ye($(i0)),Ye($(i0)),Ye($(i0))),offset:o0[2],index:o0[2]/128,roll:e[Math.random()*e.length-1|0]}];if(l)for(var c0=0;c0<l;c0++)a0.push({data:[].concat(Ye($(i0)),Ye($(i0)),Ye($(i0))),offset:o0[2],index:o0[2]/128,roll:e[Math.random()*e.length-1|0]}),o0.push(128*(1+Math.random()*(i0.length-1)*3|0));var s0=a0[0].data[a0[0].index],u0=a0.every(function(e){return e.data[e.index].id===s0.id});if(u0&&window.electron.activateAchievement("jackpot"),u0&&-1===s0.id)continue;n.onFinish(a0.map(function(e){return{roll:e.roll,item:e.data[e.index]}})),o();break}}'
$source = $source.Substring(0, $slotStart) + $slotReplacement + $source.Substring($slotEnd + 1)

# Price Wheel: generate the same wheel entries and landing index immediately.
$wheelStart = $source.IndexOf('h=(0,e.useCallback)(function(){var e,t=n.types,r=n.rolls;', [StringComparison]::Ordinal)
$wheelEndMarker = '},[n.types,n.rolls]);return(0,e.useEffect)(function(){n.open&&h()},[n])'
$wheelEnd = $source.IndexOf($wheelEndMarker, $wheelStart, [StringComparison]::Ordinal)
if ($wheelStart -lt 0 -or $wheelEnd -lt 0) { throw 'Price Wheel callback boundaries not found' }
$wheelReplacement = 'h=(0,e.useCallback)(function(){var e=n.types,t=n.rolls,o0=24+(108*Math.random()|0),a0=Array.from(e);while(a0.length<11){var l0=Math.min(Math.round(Math.random()*e.length),e.length-1);a0.push(e[l0])}a0.push({id:-1}),a0=$(a0).map(function(e){return eo(eo({},e),{},{roll:t[Math.random()*t.length|0]*(1===e.id?10:1)})});var r0=a0[Math.abs(o0%12)];r0.id<0&&window.electron.activateAchievement("house-always-wins"),n.onFinish({item:r0,roll:r0.roll}),i()}'
$source = $source.Substring(0, $wheelStart) + $wheelReplacement + $source.Substring($wheelEnd + 1)

[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))
$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Skipped Slot Machine and Price Wheel animations: $bundle"
Write-Output "Backup: $backup"
Write-Output "Patched SHA256: $newHash"
