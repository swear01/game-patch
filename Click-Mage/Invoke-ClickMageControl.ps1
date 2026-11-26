[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('status', 'speed', 'render', 'watch', 'scan', 'catalog', 'click', 'collect', 'drop', 'ship', 'shipbatch', 'recipe', 'upgrade', 'build', 'save', 'saves', 'load', 'ending', 'continueending')]
    [string]$Action,

    [double]$X,
    [double]$Y,

    [ValidateRange(1, 160)]
    [int]$Count = 1,

    [ValidateRange(0.1, 6.0)]
    [double]$Seconds = 0.5,

    [ValidateRange(1.0, 32.0)]
    [double]$Multiplier,

    [ValidateRange(0, 2)]
    [int]$VSync,

    [ValidateRange(30, 480)]
    [int]$MaxFps,

    [switch]$WatchOff,

    [switch]$Windowed,

    [switch]$Borderless,

    [ValidateSet('all', 'resources', 'nodes', 'buildings')]
    [string]$Kind = 'all',

    [string]$Resource,

    [ValidateSet('Any', 'Loose', 'Chest')]
    [string]$From = 'Any',

    [double]$SourceX,

    [double]$SourceY,

    [ValidateRange(0.1, 1000.0)]
    [double]$SourceRadius = 8,

    [ValidateCount(1, 12)]
    [hashtable[]]$Transfers,

    [int]$TargetId,

    [string]$Recipe,

    [string]$Upgrade,

    [string]$Building,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$SaveCounter,

    [string]$SaveName,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$GameProcessId,

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
$Action = $Action.ToLowerInvariant()
$usesCoordinates = $Action -in @('click', 'collect', 'drop', 'ship', 'build')
$watchCoordinates = $Action -eq 'watch' -and
    ($PSBoundParameters.ContainsKey('X') -or $PSBoundParameters.ContainsKey('Y'))
$usesDuration = $Action -in @('collect', 'drop')
$actionParameters = @{
    X = $usesCoordinates -or $watchCoordinates
    Y = $usesCoordinates -or $watchCoordinates
    Count = $Action -in @('click', 'collect', 'drop', 'ship')
    Seconds = $usesDuration
    Multiplier = $Action -eq 'speed'
    VSync = $Action -eq 'render'
    MaxFps = $Action -eq 'render'
    WatchOff = $Action -eq 'watch'
    Windowed = $Action -eq 'render'
    Borderless = $Action -eq 'render'
    Kind = $Action -eq 'scan'
    Resource = $Action -in @('collect', 'ship')
    From = $Action -eq 'ship'
    SourceX = $Action -eq 'ship'
    SourceY = $Action -eq 'ship'
    SourceRadius = $Action -eq 'ship'
    Transfers = $Action -eq 'shipbatch'
    TargetId = $Action -eq 'recipe'
    Recipe = $Action -eq 'recipe'
    Upgrade = $Action -eq 'upgrade'
    Building = $Action -eq 'build'
    SaveCounter = $Action -eq 'load'
    SaveName = $Action -eq 'load'
}
foreach ($name in $actionParameters.Keys) {
    if ($PSBoundParameters.ContainsKey($name) -and !$actionParameters[$name]) {
        throw "The '$Action' action does not accept -$name."
    }
}
if (($usesCoordinates -or $watchCoordinates) -and (!$PSBoundParameters.ContainsKey('X') -or !$PSBoundParameters.ContainsKey('Y'))) {
    throw "The '$Action' action requires -X and -Y in Unity world coordinates."
}
if (($usesCoordinates -or $watchCoordinates) -and ([double]::IsNaN($X) -or [double]::IsInfinity($X) -or
        [double]::IsNaN($Y) -or [double]::IsInfinity($Y))) {
    throw 'Coordinates must be finite numbers.'
}
if ($Action -eq 'speed' -and !$PSBoundParameters.ContainsKey('Multiplier')) {
    throw 'The speed action requires -Multiplier.'
}
if ($actionParameters.TargetId -and !$TargetId) { throw "'$Action' needs -TargetId." }
if ($actionParameters.Recipe -and !$Recipe) { throw 'Select a recipe with -Recipe.' }
if ($actionParameters.Upgrade -and !$Upgrade) { throw 'Select an upgrade with -Upgrade.' }
if ($actionParameters.Building -and !$Building) { throw 'Select a blueprint with -Building.' }
if ($Action -eq 'load' -and !$PSBoundParameters.ContainsKey('SaveCounter')) { throw 'Select a save with -SaveCounter.' }
if ($Action -eq 'ship' -and (!$Resource -or !$PSBoundParameters.ContainsKey('Count') -or $Count -gt 40)) {
    throw 'Ship requires -Resource and -Count between 1 and 40.'
}
if ($Windowed -and $Borderless) { throw 'Choose one display mode.' }
if ($PSBoundParameters.ContainsKey('SourceX') -ne $PSBoundParameters.ContainsKey('SourceY')) {
    throw 'Provide both -SourceX and -SourceY when filtering the shipping source.'
}
if ($Action -eq 'click' -and !$PSBoundParameters.ContainsKey('TimeoutSeconds')) {
    $TimeoutSeconds = [Math]::Max($TimeoutSeconds, 5 + [Math]::Ceiling($Count / 5.0))
}

if ($Action -eq 'shipbatch') {
    if (!$Transfers.Count) { throw 'Shipbatch requires -Transfers with 1 to 12 transfer hashtables.' }

    function Get-TransferNumber {
        param($Value, [string]$Key, [int]$Entry, [double]$Minimum, [double]$Maximum)

        $code = if ($null -eq $Value) { [TypeCode]::Empty } else { [Type]::GetTypeCode($Value.GetType()) }
        if ($Value -is [Enum] -or $code -lt [TypeCode]::SByte -or $code -gt [TypeCode]::Decimal) {
            throw "Transfer $Entry requires a numeric '$Key'."
        }
        $number = [double]$Value
        if ([double]::IsNaN($number) -or $number -lt $Minimum -or $number -gt $Maximum) {
            throw "Transfer $Entry '$Key' must be between $Minimum and $Maximum."
        }
        $number
    }

    # ResourceType names from the supported Click Mage build. The game also validates the name.
    $resourceTypes = @(
        'wood', 'stone', 'water', 'ironOre', 'copperOre', 'crystal', 'ironIngot', 'copperIngot', 'sand',
        'plank', 'stoneBlock', 'crystalDust', 'woodChips', 'woodPulp', 'paper', 'glass', 'ironPlate',
        'copperWire', 'copperSheet', 'copperPipe', 'charcoal', 'nails', 'scroll', 'phial', 'eventResource',
        'steelBeam', 'earthEssence', 'ironEssence', 'waterEssence', 'fireEssence', 'woodEssence',
        'copperEssence', 'crystalEssence', 'emptyEnergyCrystal', 'catalyst', 'ash', 'steelIngot'
    )
    $transferKeys = 'x', 'y', 'resource', 'count', 'from', 'sourceX', 'sourceY', 'sourceRadius'
    $batchTransfers = @(for ($index = 0; $index -lt $Transfers.Count; $index++) {
        $entry = $index + 1
        $transfer = $Transfers[$index]
        if ($null -eq $transfer) { throw "Transfer $entry must be a hashtable." }

        $fields = @{}
        foreach ($key in $transfer.Keys) {
            if ($key -isnot [string] -or $key -notin $transferKeys) {
                throw "Transfer $entry has an unsupported key '$key'."
            }
            if ($fields.ContainsKey($key)) { throw "Transfer $entry repeats key '$key'." }
            $fields[$key] = $transfer[$key]
        }
        if ($fields.resource -isnot [string] -or $fields.resource -notin $resourceTypes) {
            throw "Transfer $entry requires a known resource type."
        }
        $quantity = Get-TransferNumber $fields['count'] 'count' $entry 1 40
        if ($quantity -ne [Math]::Truncate($quantity)) { throw "Transfer $entry 'count' must be a whole number." }

        $record = @{
            x = Get-TransferNumber $fields.x 'x' $entry -1000 1000
            y = Get-TransferNumber $fields.y 'y' $entry -1000 1000
            resource = $fields.resource
            count = [int]$quantity
        }
        if ($fields.ContainsKey('from')) {
            if ($fields.from -isnot [string] -or $fields.from -notin @('Any', 'Loose', 'Chest')) {
                throw "Transfer $entry 'from' must be Any, Loose, or Chest."
            }
            $record.from = $fields.from
        }
        $hasSourceX = $fields.ContainsKey('sourceX')
        if ($hasSourceX -ne $fields.ContainsKey('sourceY') -or ($fields.ContainsKey('sourceRadius') -and !$hasSourceX)) {
            throw "Transfer $entry requires both 'sourceX' and 'sourceY' when filtering the source."
        }
        if ($hasSourceX) {
            $record.sourceX = Get-TransferNumber $fields.sourceX 'sourceX' $entry -1000 1000
            $record.sourceY = Get-TransferNumber $fields.sourceY 'sourceY' $entry -1000 1000
            if ($fields.ContainsKey('sourceRadius')) {
                $record.sourceRadius = Get-TransferNumber $fields.sourceRadius 'sourceRadius' $entry 0.1 1000
            }
        }
        $record
    })
}

$games = if ($GameProcessId) {
    @(Get-Process -Id $GameProcessId -ErrorAction SilentlyContinue | Where-Object ProcessName -eq 'ClickMage')
} else {
    @(Get-Process -Name ClickMage -ErrorAction SilentlyContinue)
}
if (!$games) {
    throw 'No matching Click Mage process is running.'
}
if (@($games).Count -ne 1) {
    throw 'More than one Click Mage process is running. Select one with -GameProcessId.'
}
$game = @($games)[0]
$directory = Join-Path $env:LOCALAPPDATA "ClickMageControl/$($game.Id)"
$readyPath = Join-Path $directory 'ready.json'
$readyFile = Get-Item -LiteralPath $readyPath -ErrorAction SilentlyContinue
if (!$readyFile -or $readyFile.LastWriteTimeUtc -lt $game.StartTime.ToUniversalTime()) {
    throw "The control API for Click Mage PID $($game.Id) is not ready."
}
$ready = [IO.File]::ReadAllText($readyPath) | ConvertFrom-Json
if ($ready.pid -ne $game.Id) {
    throw "The control API reported an unexpected process ID for Click Mage PID $($game.Id)."
}
$session = [guid]::Empty
if ($ready.protocol -ne 1 -or ![guid]::TryParseExact($ready.session, 'N', [ref]$session)) {
    throw 'The Click Mage control protocol does not match this client.'
}
if ($Action -in @('ending', 'continueending')) {
    $endingPath = Join-Path $directory 'ending.json'
    if ([IO.File]::Exists($endingPath)) {
        $ending = [IO.File]::ReadAllText($endingPath) | ConvertFrom-Json
        if ($ending.session -eq $session.ToString('N') -and $ending.status.completed) {
            $game.Dispose()
            return $ending.status
        }
    }
}

$id = [guid]::NewGuid().ToString('N')
$message = @{ id = $id; action = $Action; session = $session.ToString('N') }
if ($usesCoordinates -or $watchCoordinates) {
    $message.x = $X
    $message.y = $Y
}
if ($TargetId) { $message.targetId = $TargetId }
if ($PSBoundParameters.ContainsKey('Count')) { $message.count = $Count }
switch ($Action) {
    'collect' {
        $message.seconds = $Seconds
        if ($Resource) { $message.resource = $Resource }
    }
    'drop' { $message.seconds = $Seconds }
    'ship' {
        $message.resource = $Resource
        $message.from = $From
        if ($PSBoundParameters.ContainsKey('SourceX')) {
            $message.sourceX = $SourceX
            $message.sourceY = $SourceY
            $message.sourceRadius = $SourceRadius
        }
    }
    'shipbatch' { $message.transfers = $batchTransfers }
    'speed' { $message.multiplier = $Multiplier }
    'render' {
        if ($PSBoundParameters.ContainsKey('VSync')) { $message.vsync = $VSync }
        if ($PSBoundParameters.ContainsKey('MaxFps')) { $message.maxFps = $MaxFps }
        if ($Windowed) { $message.windowed = $true }
        if ($Borderless) { $message.borderless = $true }
    }
    'watch' { $message.enabled = !$WatchOff }
    'scan' { $message.kind = $Kind.ToLowerInvariant() }
    'recipe' { $message.recipe = $Recipe }
    'upgrade' { $message.upgrade = $Upgrade }
    'build' { $message.building = $Building }
    'load' {
        $message.saveCounter = $SaveCounter
        if ($SaveName) { $message.saveName = $SaveName }
    }
}

$lockPath = Join-Path $directory 'client.lock'
$requestPath = Join-Path $directory 'request.json'
$responsePath = Join-Path $directory 'response.json'
$temporaryPath = Join-Path $directory "$id.tmp"
$watch = [Diagnostics.Stopwatch]::StartNew()
$lease = $null
try {
    while (!$lease -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $lease = [IO.File]::Open($lockPath, 'OpenOrCreate', 'Write', 'None')
        } catch {
            if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -notin 32, 33) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
    if (!$lease) {
        throw 'Timed out waiting for the Click Mage control client lock.'
    }

    [IO.File]::WriteAllText($temporaryPath, ($message | ConvertTo-Json -Depth 4 -Compress), [Text.UTF8Encoding]::new($false))
    $published = $false
    while (!$published -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds -and !$game.HasExited) {
        try {
            [IO.File]::Move($temporaryPath, $requestPath)
            $published = $true
        } catch {
            if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -notin 32, 33, 80, 183) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
    if (!$published) {
        throw "Could not queue '$Action' for the running Click Mage process."
    }

    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds -and !$game.HasExited) {
        $reply = $null
        if ([IO.File]::Exists($responsePath)) {
            try {
                $reply = [IO.File]::ReadAllText($responsePath) | ConvertFrom-Json
            } catch {
                if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -notin 2, 32, 33) { throw }
            }
        }
        if ($reply -and $reply.id -eq $id) {
            if ($reply.ok -isnot [bool]) {
                throw "Invalid reply from Click Mage for '$Action'."
            }
            if (!$reply.ok) {
                throw "Click Mage rejected '$Action'. $($reply.error)"
            }
            return $reply.result
        }
        Start-Sleep -Milliseconds 50
    }
    throw "No reply from Click Mage for '$Action'. Request $id may still execute."
} finally {
    try {
        [IO.File]::Delete($temporaryPath)
    } finally {
        if ($lease) { $lease.Dispose() }
        $game.Dispose()
    }
}
