#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$OutputPath,
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox')
)

$ErrorActionPreference = 'Stop'
$control = Join-Path $PSScriptRoot 'Invoke-Shelldiver.ps1'
$snapshot = & $control -Action snapshot -Mailbox $Mailbox
$game = Get-Process -Id $snapshot.pid
. (Join-Path $PSScriptRoot 'ShelldiverIdentity.ps1')
Assert-ShelldiverIdentity $game
if (!$game.MainWindowHandle) {
    throw 'The resident native Shelldiver window is unavailable.'
}

Add-Type -AssemblyName System.Drawing
if (!('ShelldiverWindowCapture' -as [type])) {
    $native = @"
using System;
using System.Runtime.InteropServices;

public static class ShelldiverWindowCapture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out Rect rectangle);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr window, IntPtr device, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
"@
    Add-Type -TypeDefinition $native
}

$foreground = [ShelldiverWindowCapture]::GetForegroundWindow()
$dpiContext = [ShelldiverWindowCapture]::SetThreadDpiAwarenessContext([IntPtr](-4))
$rect = [ShelldiverWindowCapture+Rect]::new()
try {
    if (![ShelldiverWindowCapture]::GetWindowRect($game.MainWindowHandle, [ref]$rect)) {
        throw 'The Shelldiver window bounds are unavailable.'
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 100 -or $height -lt 100 -or $width -gt 8000 -or $height -gt 5000) {
        throw 'Unexpected Shelldiver window size.'
    }
    $image = [Drawing.Bitmap]::new($width, $height)
    try {
        $graphics = [Drawing.Graphics]::FromImage($image)
        try {
            $dc = $graphics.GetHdc()
            try { $captured = [ShelldiverWindowCapture]::PrintWindow($game.MainWindowHandle, $dc, 2) }
            finally { $graphics.ReleaseHdc($dc) }
        } finally { $graphics.Dispose() }
        if (!$captured) { throw 'Shelldiver did not provide a window frame.' }
        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $image.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $image.Dispose() }
} finally {
    if ($dpiContext) { $null = [ShelldiverWindowCapture]::SetThreadDpiAwarenessContext($dpiContext) }
}

[pscustomobject]@{
    path = $path
    pid = $snapshot.pid
    room = $snapshot.room
    width = $width
    height = $height
    foregroundUnchanged = [ShelldiverWindowCapture]::GetForegroundWindow() -eq $foreground
}
