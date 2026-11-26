param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'capture', 'type', 'submit', 'hint')]
    [string]$Command,
    [string]$Answer,
    [string]$Output
)

$ErrorActionPreference = 'Stop'
$directory = Join-Path $env:LOCALAPPDATA 'CypherAssist'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$requestId = [Guid]::NewGuid().ToString('N')
$pending = Join-Path $directory "$requestId.tmp"
$request = Join-Path $directory "$requestId.request"
$result = Join-Path $directory "$requestId.result"
$screenshot = Join-Path $directory "$requestId.png"
$payload = $Command.ToLowerInvariant()
if ($payload -in @('type', 'submit')) {
    if ([string]::IsNullOrWhiteSpace($Answer) -or $Answer.Length -gt 48 -or $Answer -match '[\r\n]') {
        throw 'Provide an answer of 1 to 48 characters on one line.'
    }
    $payload += "`n$Answer"
}

function Test-CompletePng([string]$Path) {
    try {
        $stream = [IO.File]::OpenRead($Path)
    } catch [IO.IOException] {
        return $false
    }
    try {
        if ($stream.Length -lt 20) { return $false }
        $signature = [byte[]]::new(8)
        $trailer = [byte[]]::new(12)
        [void]$stream.Read($signature, 0, $signature.Length)
        [void]$stream.Seek(-12, [IO.SeekOrigin]::End)
        [void]$stream.Read($trailer, 0, $trailer.Length)
        return ([BitConverter]::ToString($signature) -eq '89-50-4E-47-0D-0A-1A-0A') -and
            ([BitConverter]::ToString($trailer) -eq '00-00-00-00-49-45-4E-44-AE-42-60-82')
    } finally {
        $stream.Dispose()
    }
}

$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    [IO.File]::WriteAllText($pending, $payload)
    [IO.File]::Move($pending, $request)
    while (-not [IO.File]::Exists($result)) {
        if ($timer.Elapsed.TotalSeconds -ge 15) {
            throw 'Cypher Assist did not respond. Check that the game restarted with the patch and that the main menu has rendered.'
        }
        Start-Sleep -Milliseconds 100
    }

    $status, $message = [IO.File]::ReadAllText($result) -split "`n", 2
    if ($status -ne 'ok') { throw $message }
    if ($Command -ne 'capture') {
        Write-Output $message
        return
    }

    while (-not (Test-CompletePng $screenshot)) {
        if ($timer.Elapsed.TotalSeconds -ge 15) {
            throw 'Unity did not produce a complete screenshot. Check that the game is running in windowed mode.'
        }
        Start-Sleep -Milliseconds 100
    }

    if (-not $Output) { $Output = Join-Path $directory 'last.png' }
    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
    Move-Item -LiteralPath $screenshot -Destination $outputPath -Force
    Write-Output $outputPath
} finally {
    foreach ($path in @($pending, $request, $result, $screenshot)) {
        try {
            [IO.File]::Delete($path)
        } catch [IO.IOException] {
            Write-Verbose "The game is still using $path"
        }
    }
}
