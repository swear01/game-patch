#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$FramePath,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Find-CatchBadge([Drawing.Bitmap]$Bitmap) {
    # The badge stays to the right of Tab and rises when the inventory opens.
    $rectangles = [Collections.Generic.List[Drawing.Rectangle]]::new()
    $top = -1
    $left = 200
    $right = 0
    $area = 0
    for ($y = 225; $y -le 405; ++$y) {
        $rowCount = 0
        if ($y -lt 405) {
            for ($x = 132; $x -lt 201; ++$x) {
                $color = $Bitmap.GetPixel($x, $y)
                if ($color.R -eq 232 -and $color.G -eq 80 -and $color.B -eq 93) {
                    ++$rowCount
                    if ($rowCount -eq 1) { $rowFirst = $x }
                    $rowLast = $x
                }
            }
        }
        if ($rowCount -ge 4) {
            if ($top -lt 0) { $top = $y }
            $left = [Math]::Min($left, $rowFirst)
            $right = [Math]::Max($right, $rowLast)
            $area += $rowCount
        } elseif ($top -ge 0) {
            $width = $right - $left + 1
            $height = $y - $top
            if ($left -in (135..149) -and $width -in (10..56) -and $height -in (7..22) -and
                $area -ge .40 * $width * $height) {
                $rectangles.Add([Drawing.Rectangle]::new($left, $top, $width, $height))
            }
            $top = -1
            $left = 200
            $right = 0
            $area = 0
        }
    }
    if ($rectangles.Count -eq 1) { return $rectangles[0] }
}

function Read-WindowsBadgeText([string]$OcrImage) {
    # Windows PowerShell supplies the Windows Runtime projection for the inbox OCR engine.
    $program = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime]
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
[void][Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
[void][Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType=WindowsRuntime]
`$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    `$_.Name -eq 'AsTask' -and `$_.IsGenericMethod -and `$_.GetParameters().Count -eq 1
} | Select-Object -First 1

function Wait-OcrResult(`$Operation, [Type]`$ResultType) {
    `$task = `$asTask.MakeGenericMethod(`$ResultType).Invoke(`$null, @(`$Operation))
    `$null = `$task.GetAwaiter().GetResult()
    return `$task.Result
}

`$language = New-Object Windows.Globalization.Language 'en-US'
`$engine = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType=WindowsRuntime]::TryCreateFromLanguage(`$language)
if (!`$engine) { throw 'Windows OCR has no English recognizer.' }
`$file = Wait-OcrResult ([Windows.Storage.StorageFile]::GetFileFromPathAsync(`$env:SHELLDIVER_BADGE_OCR_FILE)) ([Windows.Storage.StorageFile])
`$stream = Wait-OcrResult (`$file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
try {
    `$decoder = Wait-OcrResult ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync(`$stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    `$bitmap = Wait-OcrResult (`$decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    try {
        (Wait-OcrResult (`$engine.RecognizeAsync(`$bitmap)) ([Windows.Media.Ocr.OcrResult])).Text
    } finally { `$bitmap.Dispose() }
} finally { `$stream.Dispose() }
"@
    $previous = $env:SHELLDIVER_BADGE_OCR_FILE
    try {
        $env:SHELLDIVER_BADGE_OCR_FILE = $OcrImage
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $result = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0) { throw 'Windows OCR could not read the Shelldiver catch badge.' }
        return ($result -join '').Trim()
    } finally { $env:SHELLDIVER_BADGE_OCR_FILE = $previous }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ("shelldiver-badge-" + [Guid]::NewGuid().ToString('N'))
$capturedPath = "$temporary-capture.png"
$ocrPath = "$temporary-ocr.png"
try {
    if (!$FramePath) {
        $capture = & (Join-Path $PSScriptRoot 'Get-ShelldiverFrame.ps1') -OutputPath $capturedPath -Mailbox $Mailbox
        if ($capture.room -notlike 'rm_ocean_*' -or !$capture.foregroundUnchanged) { return }
        $FramePath = $capture.path
    }

    $source = [Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $FramePath).ProviderPath)
    try {
        if ([Math]::Abs($source.Width / $source.Height - (16.0 / 9)) -gt .07) { return }
        $view = [Drawing.Bitmap]::new(720, 405)
        try {
            $graphics = [Drawing.Graphics]::FromImage($view)
            try {
                $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
                $graphics.DrawImage($source, 0, 0, 720, 405)
            } finally { $graphics.Dispose() }

            $badge = Find-CatchBadge $view
            if (!$badge) { return }
            $isSingle = $badge.Width -le 19
            $useNativePixels = $badge.Width -ge 36
            $badge.Inflate(1, 2)
            $badge.Intersect([Drawing.Rectangle]::new(0, 0, 720, 405))
            $pixels = $view
            $scaleX = $scaleY = 1.0
            $greenMin = $blueMin = if ($isSingle) { 180 } else { 196 }
            $padding = 5
            if ($useNativePixels) {
                # The wide FULL label needs its original pixel detail.
                $pixels = $source
                $scaleX = $source.Width / 720.0
                $scaleY = $source.Height / 405.0
                $greenMin = 152
                $blueMin = 155
                $padding = 6
            }
            $left = [int][Math]::Floor($badge.Left * $scaleX)
            $top = [int][Math]::Floor($badge.Top * $scaleY)
            $width = [int][Math]::Ceiling($badge.Right * $scaleX) - $left
            $height = [int][Math]::Ceiling($badge.Bottom * $scaleY) - $top
            $text = [Drawing.Bitmap]::new(($width + $padding * 2), ($height + $padding * 2))
            try {
                $graphics = [Drawing.Graphics]::FromImage($text)
                try { $graphics.Clear([Drawing.Color]::White) } finally { $graphics.Dispose() }
                $markLeft = $text.Width
                $markTop = $text.Height
                $markRight = $markBottom = -1
                for ($y = 0; $y -lt $height; ++$y) {
                    for ($x = 0; $x -lt $width; ++$x) {
                        $color = $pixels.GetPixel(($left + $x), ($top + $y))
                        if ($color.R -ge 216 -and $color.G -ge $greenMin -and $color.B -ge $blueMin) {
                            $maskX = $x + $padding
                            $maskY = $y + $padding
                            $text.SetPixel($maskX, $maskY, [Drawing.Color]::Black)
                            if ($isSingle) {
                                $markLeft = [Math]::Min($markLeft, $maskX)
                                $markTop = [Math]::Min($markTop, $maskY)
                                $markRight = [Math]::Max($markRight, $maskX)
                                $markBottom = [Math]::Max($markBottom, $maskY)
                            }
                        }
                    }
                }
                $upscale = if ($useNativePixels) { [int][Math]::Ceiling(125.0 / $height) } else { 8 }
                $glyph = [Drawing.Rectangle]::new(0, 0, $text.Width, $text.Height)
                $copies = 1
                $border = 0
                if ($isSingle) {
                    # The Windows engine often ignores one tiny digit. Present three copies and require agreement.
                    if (($markRight - $markLeft + 1) -notin (2..10) -or
                        ($markBottom - $markTop + 1) -notin (4..10)) { return }
                    $glyph = [Drawing.Rectangle]::FromLTRB($markLeft, $markTop, $markRight + 1, $markBottom + 1)
                    $copies = 3
                    $border = 3
                }
                $stride = ($glyph.Width + 2) * $upscale
                $scaledWidth = $stride * ($copies - 1) + ($glyph.Width + 2 * $border) * $upscale
                $scaledHeight = ($glyph.Height + 2 * $border) * $upscale
                $scaled = [Drawing.Bitmap]::new($scaledWidth, $scaledHeight)
                try {
                    $graphics = [Drawing.Graphics]::FromImage($scaled)
                    try {
                        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
                        $graphics.Clear([Drawing.Color]::White)
                        for ($copy = 0; $copy -lt $copies; ++$copy) {
                            $leftPx = $copy * $stride + $border * $upscale
                            $clip = [Drawing.Rectangle]::new($leftPx, ($border * $upscale),
                                ($glyph.Width * $upscale), ($glyph.Height * $upscale))
                            $graphics.DrawImage($text, $clip, $glyph, [Drawing.GraphicsUnit]::Pixel)
                        }
                    } finally { $graphics.Dispose() }
                    $scaled.Save($ocrPath, [Drawing.Imaging.ImageFormat]::Png)
                } finally { $scaled.Dispose() }
            } finally { $text.Dispose() }
        } finally { $view.Dispose() }
    } finally { $source.Dispose() }

    $label = Read-WindowsBadgeText $ocrPath
    if ($isSingle) {
        if ($label -cmatch '^(?<digit>[1-9])\s*\k<digit>\s*\k<digit>$') { return [int]$Matches['digit'] }
        return
    }
    if ($label -match '^FULL!?$') { return 'full' }
    $count = 0
    if ($label -match '^\d+$' -and [int]::TryParse($label, [ref]$count)) { return $count }
} finally {
    [IO.File]::Delete($capturedPath)
    [IO.File]::Delete($ocrPath)
}