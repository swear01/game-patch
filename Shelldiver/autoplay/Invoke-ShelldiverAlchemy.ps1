[CmdletBinding()]
param(
    [ValidateRange(1, 100)] [int]$Vials = 1,
    [ValidateRange(10, 14400)] [int]$TimeoutSeconds = 180,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),
    [string]$SavePath = (Join-Path $env:APPDATA 'Shelldiver/save/Game.json')
)

$ErrorActionPreference = 'Stop'
if (!$PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds = 25 + 120 * $Vials }
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$island = Join-Path $PSScriptRoot 'Invoke-ShelldiverIsland.ps1'
$Mailbox = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Mailbox)
$price = [decimal]100000000000000
$walletFields = 'shell_coins', 'store_shell_coins', 'alchemy_shell_coins', 'store_flask_coins', 'flask_coins'
$timer = [Diagnostics.Stopwatch]::StartNew()
$gamePid = $null
$phase = 'preflight'

function Get-Budget([int]$Maximum = 5) {
    $left = [int][Math]::Floor($TimeoutSeconds - $timer.Elapsed.TotalSeconds)
    if ($left -lt 1) { throw "Timed out during $phase." }
    return [Math]::Min($Maximum, $left)
}

function Read-AlchemySave {
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $file = [IO.File]::Open($SavePath, 'Open', 'Read', $share)
        try {
            $reader = [IO.StreamReader]::new($file)
            try { $encoded = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        } finally {
            $file.Dispose()
        }
        $raw = [Convert]::FromHexString($encoded)
        if ($raw.Length -le 16) { return }
        $json = [Text.Encoding]::UTF8.GetString($raw, 16, $raw.Length - 16).TrimEnd([char]0)
        $doc = [Text.Json.JsonDocument]::Parse($json)
        try {
            $data = $doc.RootElement
            $wallet = [ordered]@{}
            foreach ($name in $walletFields) { $wallet[$name] = $data.GetProperty($name).GetDecimal() }
            $ranks = $data.GetProperty('skills_saved')
            $station = [Text.Json.JsonElement]::new()
            $unlocked = $ranks.TryGetProperty('o_skill_alchemy_station', [ref]$station) -and
                $station.GetDecimal() -ge 1 -and $data.GetProperty('alchemy_station_available').GetBoolean()
            $extraVial = $false
            foreach ($skill in 'o_skill_alchemy_station_dc_01', 'o_skill_alchemy_station_dc_02') {
                $rank = [Text.Json.JsonElement]::new()
                if ($ranks.TryGetProperty($skill, [ref]$rank) -and $rank.GetDecimal() -ge 1) {
                    $extraVial = $true
                }
            }
            return [pscustomobject]@{ wallet = $wallet; unlocked = $unlocked; extraVial = $extraVial }
        } finally {
            $doc.Dispose()
        }
    } catch [IO.IOException], [FormatException], [Text.Json.JsonException] { return }
}

function Read-Island {
    $state = & $control -Action snapshot -Mailbox $Mailbox -TimeoutSeconds (Get-Budget)
    if ($state.room -ne 'rm_main_island' -or ($gamePid -and $state.pid -ne $gamePid)) {
        throw "The resident island changed during $phase."
    }
    if (!$state.pid -or !$state.inputReady -or !$state.flags.files_loaded -or
        $state.flags.transitioning -or $state.flags.pause -or $state.flags.player_inventory_open -or
        $state.flags.in_cutscene -or $state.guiPointer.active -or $null -eq $state.scene.player.x) {
        throw "The island is not settled during $phase."
    }
    if ($state.inputError -and $state.inputError -ne 'Could not publish the game mailbox response.') {
        throw "Native input reported an error during $($phase). $($state.inputError)"
    }
    return $state
}

function Wait-Island([long]$AfterFrame) {
    while ($true) {
        $state = Read-Island
        if ($state.frame -gt $AfterFrame -and $state.activeInputFrames -eq 0 -and
            ($null -eq $state.scene.player.frame -or $state.scene.player.frame -gt $AfterFrame)) {
            return $state
        }
        Start-Sleep -Milliseconds 25
    }
}

function Get-Amount($Value) {
    if ($null -eq $Value) { throw "Missing native balance during $phase." }
    if ($Value -is [double]) {
        $culture = [Globalization.CultureInfo]::InvariantCulture
        return [decimal]::Parse($Value.ToString('R', $culture), [Globalization.NumberStyles]::Float, $culture)
    }
    return [decimal]$Value
}

function Read-Wallet($State, $Saved) {
    $wallet = [ordered]@{}
    foreach ($name in $walletFields) {
        $value = $State.numbers.$name
        if ($null -eq $value) {
            if ($name -notin 'alchemy_shell_coins','store_flask_coins') { throw "Missing live $name during $phase." }
            while (!$Saved) {
                $null=Get-Budget
                $Saved=Read-AlchemySave
                if (!$Saved) { Start-Sleep -Milliseconds 40 }
            }
            $value=$Saved.wallet[$name]
        }
        $wallet[$name] = Get-Amount $value
    }
    return $wallet
}

function Wait-Checkpoint([scriptblock]$Ready) {
    while ($true) {
        $state = Read-Island
        $save = Read-AlchemySave
        if ($state.activeInputFrames -eq 0 -and $save) {
            $wallet = Read-Wallet $state $save
            if (& $Ready $wallet $save) {
                return [pscustomobject]@{ wallet = $wallet; save = $save }
            }
        }
        Start-Sleep -Milliseconds 75
    }
}

function Assert-Balance($Wallet, [decimal]$Shells, [decimal]$StoreShells) {
    if ($Wallet.shell_coins -ne $Shells -or $Wallet.store_shell_coins -lt $StoreShells) {
        throw "Unexpected shell balances during $phase. Current wallet $($Wallet.shell_coins) and shop $($Wallet.store_shell_coins)."
    }
}

function Invoke-HoldPulse([double]$X, $State) {
    if ($State.activeInputFrames -ne 0 -or [Math]::Abs($State.scene.player.x - $X) -gt 8) {
        throw "The player or native input moved before $phase."
    }
    $reply = & $control -Action input -ParametersJson '{"frames":1,"values":{"interact":1,"interact_hold":true}}' -Mailbox $Mailbox -TimeoutSeconds (Get-Budget)
    if ($null -eq $reply.frame -or $reply.frame -lt $State.frame) {
        throw "Native input acknowledgement was invalid during $phase."
    }
    return Wait-Island ([long]$reply.frame)
}

function Move-ToExchange([double]$X) {
    $budget = Get-Budget 25
    if ($budget -lt 3) { throw "Too little time remains to move during $phase." }
    $state = & $island -Action Move -X $X -Tolerance 6 -Mailbox $Mailbox -TimeoutSeconds $budget
    return Wait-Island ([long]$state.frame)
}

if (!(Test-Path -LiteralPath $Mailbox -PathType Container)) {
    throw 'A resident Shelldiver mailbox is required.'
}
try {
    $lease = [IO.File]::Open((Join-Path $Mailbox 'session.lock'), 'OpenOrCreate', 'Write', 'None')
} catch [IO.IOException] {
    throw 'A Shelldiver session command already owns this mailbox.'
}

$receipts = [Collections.Generic.List[object]]::new()
try {
    $initial = Read-Island
    $gamePid = $initial.pid
    $state = Wait-Island ([long]$initial.frame)
    $save = Read-AlchemySave
    if (!$save -or !$save.unlocked -or ($null -ne $state.flags.alchemy_station_available -and !$state.flags.alchemy_station_available)) {
        throw 'The native Game.json must show the purchased Alchemy Station and its activation.'
    }
    if ($state.scene.alchemyStation -and ($state.scene.alchemyStation.x -ne 2765 -or $state.scene.alchemyStation.y -ne 401)) {
        throw 'The native Alchemy Station is absent at its stock island position.'
    }
    $before = Read-Wallet $state $save
    foreach ($name in $walletFields) {
        if ($name -eq 'store_shell_coins' -and $before[$name] -ge $save.wallet[$name]) { continue }
        # A stock bonus can appear after the base vial already triggered a save.
        if ($name -eq 'store_flask_coins' -and $save.extraVial -and $save.wallet[$name] -eq 1 -and
            $before[$name] -eq 2 -and $before.alchemy_shell_coins -eq 0) { continue }
        if ($before[$name] -ne $save.wallet[$name]) {
            throw "Live and saved balances disagree on $name. Wait for the native save."
        }
    }
    $resume = $before.alchemy_shell_coins -eq $price -or $before.store_flask_coins -gt 0
    $maxYield = if ($save.extraVial) { 2 } else { 1 }
    if ($before.alchemy_shell_coins -notin 0,$price -or $before.store_flask_coins -lt 0 -or
        $before.store_flask_coins -gt $maxYield -or ($before.alchemy_shell_coins -gt 0 -and $before.store_flask_coins -gt 0)) {
        throw 'The outstanding native station balances exceed a single exchange.'
    }
    $newExchanges = $Vials - [int]$resume
    if ($before.shell_coins -lt $price * $newExchanges) {
        throw "The player wallet needs $($price * $newExchanges) shell coins for $newExchanges new base exchange(s)."
    }

    $stationX = 2749.0 # Native x=2765 and range_xoffset=-16.
    $chestX = 2837.0   # Outside the station's 50-pixel interaction range.
    $expectedShells = $before.shell_coins
    $expectedVials = $before.flask_coins
    $storeShells = $before.store_shell_coins

    for ($exchange = 1; $exchange -le $Vials; $exchange++) {
        $phase = "funding exchange $exchange"
        $alreadyFunded = $resume -and $exchange -eq 1
        if ($alreadyFunded) {
            $fundedCheckpoint = [pscustomobject]@{wallet=$before}
        } else {
            $state = Move-ToExchange $stationX
            $funded = $false
            for ($attempt = 1; $attempt -le 3 -and !$funded; $attempt++) {
                $wallet = Read-Wallet $state
                Assert-Balance $wallet $expectedShells $storeShells
                if ($wallet.alchemy_shell_coins -ne 0 -or $wallet.store_flask_coins -ne 0 -or
                    $wallet.flask_coins -ne $expectedVials) {
                    throw 'Alchemy balances changed before the deposit.'
                }
                $state = Invoke-HoldPulse $stationX $state
                $debit = $expectedShells - (Get-Amount $state.numbers.shell_coins)
                if ($debit -eq 0) {
                    $state = Wait-Island ([long]$state.frame + 15)
                    $debit = $expectedShells - (Get-Amount $state.numbers.shell_coins)
                }
                if ($debit -ne 0 -and $debit -ne $price) { throw "Unexpected station debit of $debit shells." }
                $funded = $debit -eq $price
            }
            if (!$funded) { throw 'The station did not accept any of the three single-frame native interactions.' }
            $expectedShells -= $price
            $phase = "verifying funded queue for exchange $exchange"
            $fundedCheckpoint = Wait-Checkpoint {
                param($wallet, $save)
                Assert-Balance $wallet $expectedShells $storeShells
                if ($wallet.alchemy_shell_coins -lt 0 -or $wallet.alchemy_shell_coins -gt $price -or
                    $wallet.store_flask_coins -lt 0 -or $wallet.store_flask_coins -gt $maxYield -or $wallet.flask_coins -ne $expectedVials) {
                    throw 'The native funded queue or vial balances differ from the exchange.'
                }
                return $wallet.alchemy_shell_coins -eq $price -or ($wallet.alchemy_shell_coins -eq 0 -and $wallet.store_flask_coins -gt 0)
            }
        }

        $phase = "waiting for production for exchange $exchange"
        $null = Move-ToExchange $chestX
        $produced = Wait-Checkpoint {
            param($wallet, $save)
            Assert-Balance $wallet $expectedShells $storeShells
            if ($wallet.alchemy_shell_coins -lt 0 -or $wallet.alchemy_shell_coins -gt $price -or
                $wallet.store_flask_coins -notin 0,1,2 -or $wallet.store_flask_coins -gt $maxYield -or
                $wallet.flask_coins -ne $expectedVials) {
                throw 'The native production queue or vial balances differ from the exchange.'
            }
            return $wallet.alchemy_shell_coins -eq 0 -and $wallet.store_flask_coins -ge 1
        }

        $phase = "collecting exchange $exchange"
        $targetVials = $expectedVials + $produced.wallet.store_flask_coins
        $state = Wait-Island ([long](Read-Island).frame)
        $settledFrame = 0L
        $collected = $null
        while (!$collected) {
            $save = Read-AlchemySave
            $wallet = Read-Wallet $state $save
            Assert-Balance $wallet $expectedShells $storeShells
            $total = $wallet.flask_coins + $wallet.store_flask_coins
            if ($wallet.alchemy_shell_coins -ne 0 -or $wallet.flask_coins -lt $expectedVials -or
                $wallet.store_flask_coins -lt 0 -or $total -gt $expectedVials + $maxYield) {
                throw "Vial collection diverged in exchange $exchange. Prior=$expectedVials, observed=$($wallet.flask_coins), stored=$($wallet.store_flask_coins), funded=$($wallet.alchemy_shell_coins), maximum=$maxYield."
            }
            if ($total -lt $targetVials) {
                # A collected vial leaves the chest before its original flight credits the player.
                # Only observe during that gap. The final saved wallet must still include the full yield.
                $settledFrame = 0L
                $state = Wait-Island ([long]$state.frame + 4)
                continue
            }
            $targetVials = $total
            if ($wallet.store_flask_coins -gt 0) {
                $settledFrame = 0L
                $state = Invoke-HoldPulse $chestX $state
                $state = Wait-Island ([long]$state.frame + 15)
                continue
            }
            if (!$settledFrame) { $settledFrame = $state.frame }
            if ($state.frame -ge $settledFrame + 60 -and $save -and $save.wallet.shell_coins -eq $expectedShells -and
                $save.wallet.store_shell_coins -ge $storeShells -and $save.wallet.alchemy_shell_coins -eq 0 -and
                $save.wallet.store_flask_coins -eq 0 -and $save.wallet.flask_coins -eq $targetVials) {
                $collected = [pscustomobject]@{wallet=$wallet; save=$save}
                break
            }
            $state = Wait-Island ([long]$state.frame + 4)
        }
        $yield = $targetVials - $expectedVials
        $receipts.Add([pscustomobject]@{
            exchange = $exchange
            resumed = $alreadyFunded
            shellsSpent = if ($alreadyFunded) { 0 } else { $price }
            queuedShells = $fundedCheckpoint.wallet.alchemy_shell_coins
            producedVials = $yield
            wallet = $collected.wallet
        })
        $expectedVials = $targetVials
    }
    [pscustomobject]@{
        pid = $gamePid
        room = 'rm_main_island'
        exchangesCompleted = $receipts.Count
        shellsSpent = $before.shell_coins - $expectedShells
        vialsCollected = $expectedVials - $before.flask_coins
        nativeSaveVerified = $true
        before = $before
        after = $receipts[$receipts.Count - 1].wallet
        exchanges = $receipts.ToArray()
    }
} catch {
    throw "Alchemy route stopped during $phase after $($receipts.Count) verified exchange(s). $($_.Exception.Message)"
} finally {
    $lease.Dispose()
}
