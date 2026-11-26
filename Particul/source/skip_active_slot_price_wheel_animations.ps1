param([Parameter(Mandatory)][string]$GameDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bundle = Join-Path $GameDir 'particul-win32-x64\resources\app\.webpack\renderer\main_window\index.js'
$expectedHash = 'C1020C666749BC1ED58B6F1D96FD30FA6448D4552EF88C16A89671F300A0A9A6'
$backup = "$bundle.before-active-spin-skip-20260904.js"

if (-not (Test-Path -LiteralPath $bundle)) { throw "Renderer bundle not found: $bundle" }
$sourceHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
if (-not (Test-Path -LiteralPath $backup)) {
    if ($sourceHash -ne $expectedHash) { throw "Unexpected renderer bundle hash: $sourceHash" }
    Copy-Item -LiteralPath $bundle -Destination $backup -Force
} else {
    $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
    if ($backupHash -ne $expectedHash) { throw "Unexpected active-spin backup hash: $backupHash" }
    if ($sourceHash -ne $expectedHash) { Copy-Item -LiteralPath $backup -Destination $bundle -Force }
}

$source = [IO.File]::ReadAllText($bundle)

# Active Slot Machine component (Zn): calculate and apply the result directly.
$slotStart = $source.IndexOf('M=function(e){var t=m[0].data[m[0].index];', [StringComparison]::Ordinal)
$slotEndMarker = '};(0,e.useEffect)(function(){U&&document.querySelectorAll(".spin")'
$slotEnd = $source.IndexOf($slotEndMarker, $slotStart, [StringComparison]::Ordinal)
if ($slotStart -lt 0 -or $slotEnd -lt 0) { throw 'Active Slot Machine callback boundaries not found' }
$slotReplacement = 'M=function(e){var t=m[0].data[m[0].index];if(U)return!1;if(b)return!1;I(null);var r=m.every(function(e){return e.data[e.index].id===t.id}),o=r&&-1===t.id;if(r&&window.electron.activateAchievement("jackpot"),!e){var a=Xn(u);if(n.current.currentMoney<a)return!1;n.current.currentMoney-=a,d({money:n.current.currentMoney}),n.current.rollCount+=1,d({rollCount:u+1})}if(window.electron.activateAchievement("slot-spin"),n.current.stats.addSpin(),o)return k(!0),E(!1),j(),!0;r&&I(m.length),r&&m.forEach(function(e){e.roll*=m.length});var a0=m.map(function(e){return{roll:e.roll,item:e.data[e.index]}});return s.upgradeChances(a0),j(),E(!1),d({rarity:s}),!0'
$source = $source.Substring(0, $slotStart) + $slotReplacement + $source.Substring($slotEnd)

# Active Price Wheel component (rr): select the landing entry directly.
$wheelStart = $source.IndexOf('P=function(){if(console.log("DO SPIN SPINNING",h)', [StringComparison]::Ordinal)
$wheelEndMarker = '},R=(0,e.useMemo)(function(){if(d.includes("professional-gambler-1"))'
$wheelEnd = $source.IndexOf($wheelEndMarker, $wheelStart, [StringComparison]::Ordinal)
if ($wheelStart -lt 0 -or $wheelEnd -lt 0) { throw 'Active Price Wheel callback boundaries not found' }
$wheelReplacement = 'P=function(){if(console.log("DO SPIN SPINNING",h),h)return!1;k();var e=nr(c);if(console.log("DO SPIN MONEY",i.current.currentMoney<e,e,i.current.currentMoney),i.current.currentMoney<e)return!1;i.current.currentMoney-=e,f({money:i.current.currentMoney}),i.current.spinCount+=1,f({spinCount:c+1});var t=24+(108*Math.random()|0),n=w.current[Math.abs(30*-t%360/30)];return window.electron.activateAchievement("spin-wheel"),i.current.stats.addRoll(),I(n),n.id<0&&window.electron.activateAchievement("house-always-wins"),i.current.rarity.upgradePrices([{item:n,roll:n.roll}]),f({rarity:i.current.rarity}),g(!1),!0'
$source = $source.Substring(0, $wheelStart) + $wheelReplacement + $source.Substring($wheelEnd)

# Remove the CSS transitions from the active reel and wheel containers too.
$source = $source.Replace('transition:"all ".concat(i,"ms ease-out")', 'transition:"none"')
$source = $source.Replace('transition:"all ".concat(r,"ms ease-out")', 'transition:"none"')

[IO.File]::WriteAllText($bundle, $source, [Text.UTF8Encoding]::new($false))
$newHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
Write-Output "Patched active Slot Machine and Price Wheel callbacks: $bundle"
Write-Output "Backup: $backup"
Write-Output "Patched SHA256: $newHash"
