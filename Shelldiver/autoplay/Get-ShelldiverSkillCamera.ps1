[CmdletBinding()]
param(
    [string]$Mailbox = (Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27/mailbox'),

    [ValidateRange(1, 2147483647)]
    [int]$ExpectedPid
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ShelldiverIdentity.ps1')

if ($PSBoundParameters.ContainsKey('Mailbox') -or !$ExpectedPid) {
    $snapshotPath = Join-Path $Mailbox 'snapshot.json'
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($snapshotPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            $reader = [IO.StreamReader]::new($stream)
            try { $snapshot = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch {
        throw "Could not read the Shelldiver mailbox snapshot '$snapshotPath'. $($_.Exception.Message)"
    }

    $snapshotPid = 0
    if (!$snapshot -or ![int]::TryParse([string]$snapshot.pid, [ref]$snapshotPid) -or $snapshotPid -le 0) {
        throw "The Shelldiver mailbox snapshot '$snapshotPath' has no valid PID."
    }
    $written = [DateTimeOffset]::MinValue
    if ($snapshot.writtenUtc -is [DateTime]) {
        $written = [DateTimeOffset]$snapshot.writtenUtc
    } elseif (!$snapshot.writtenUtc -or ![DateTimeOffset]::TryParse([string]$snapshot.writtenUtc, [ref]$written)) {
        throw "The Shelldiver mailbox snapshot '$snapshotPath' has no valid write timestamp."
    }
    $age = ([DateTimeOffset]::UtcNow - $written).TotalSeconds
    if ($age -lt -2 -or $age -gt 5) {
        throw "The Shelldiver mailbox snapshot '$snapshotPath' is stale (age $([Math]::Round($age, 2)) seconds)."
    }
    if ($ExpectedPid -and $ExpectedPid -ne $snapshotPid) {
        throw "The Shelldiver mailbox PID $snapshotPid differs from expected PID $ExpectedPid."
    }
    $ExpectedPid = $snapshotPid
}

if (!('ShelldiverSkillCamera.NativeReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ShelldiverSkillCamera
{
    public static class NativeReader
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer,
            UIntPtr length, out UIntPtr bytesRead);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

function Read-GameBytes([long]$Address, [int]$Length, [string]$Field) {
    if ($Address -le 0) { throw "The resident game has no address for $Field." }
    $buffer = [byte[]]::new($Length)
    $count = [UIntPtr]::Zero
    if (![ShelldiverSkillCamera.NativeReader]::ReadProcessMemory(
            $handle, [IntPtr]$Address, $buffer, [UIntPtr]$Length, [ref]$count) -or
        $count.ToUInt64() -ne $Length) {
        throw "Could not read $Field from Shelldiver PID $ExpectedPid."
    }
    return ,$buffer
}

function Read-GamePointer([long]$Address, [string]$Field) {
    return [BitConverter]::ToInt64((Read-GameBytes $Address 8 $Field), 0)
}

function Read-GameInt32([long]$Address, [string]$Field) {
    return [BitConverter]::ToInt32((Read-GameBytes $Address 4 $Field), 0)
}

function Read-SkillCamera {
    $globalObject = Read-GamePointer ($moduleBase + 0xDB7A20) 'the global object'
    $vtable = Read-GamePointer $globalObject 'the global object vtable'
    if ((Read-GamePointer ($vtable + 8) 'the global lookup function') -ne $moduleBase + 0x4B1880) {
        throw 'The resident Shelldiver global lookup layout differs from the verified build.'
    }

    $table = Read-GamePointer ($globalObject + 8) 'the global variable table'
    $mask = Read-GameInt32 ($table + 8) 'the global variable table mask'
    if ($mask -lt 1 -or $mask -gt 131071 -or (($mask + 1) -band $mask) -ne 0) {
        throw 'The resident Shelldiver global variable table has an invalid mask.'
    }
    $entries = Read-GamePointer ($table + 16) 'the global variable table entries'
    $buckets = Read-GameBytes $entries (16 * ($mask + 1)) 'the global variable table entries'

    $camera = @{}
    foreach ($field in $cameraFields.GetEnumerator()) {
        $id = Read-GameInt32 ($moduleBase + $field.Value) $field.Key
        if ($id -le 0) { throw "The resident game has no initialized ID for '$($field.Key)'." }
        $hash = ($id + 1) -band 0x7fffffff
        for ($probe = 0; $probe -le $mask; ++$probe) {
            $bucket = (($hash + $probe) -band $mask) * 16
            $entryHash = [BitConverter]::ToInt32($buckets, $bucket + 12)
            if ($entryHash -eq 0) { break }
            if ($entryHash -ne $hash) { continue }
            $slot = [BitConverter]::ToInt64($buckets, $bucket)
            $value = Read-GameBytes $slot 16 $field.Key
            if ([BitConverter]::ToInt32($value, 12) -ne 0) {
                throw "Shelldiver camera field '$($field.Key)' has a non-real value."
            }
            $camera[$field.Key] = [BitConverter]::ToDouble($value, 0)
            if (![double]::IsFinite($camera[$field.Key])) {
                throw "Shelldiver camera field '$($field.Key)' is non-finite."
            }
            break
        }
        if (!$camera.ContainsKey($field.Key)) { throw "Shelldiver camera field '$($field.Key)' is absent." }
    }

    if ((Read-GamePointer ($moduleBase + 0xDB7A20) 'the global object') -ne $globalObject -or
        (Read-GamePointer ($table + 16) 'the global variable table entries') -ne $entries) {
        throw 'The resident Shelldiver global state changed during the camera read.'
    }
    return $camera
}

$cameraFields = @{
    skill_ui_xoffset = 0xD81108
    skill_ui_yoffset = 0xD811A8
    ui_zoom_factor_goal = 0xD810F8
    shake_x = 0xD831F8
    shake_y = 0xD83118
}

$process = Get-Process -Id $ExpectedPid -ErrorAction SilentlyContinue
if (!$process) { throw "Shelldiver PID $ExpectedPid is no longer running." }
try {
    Assert-ShelldiverIdentity $process
    $startTime = $process.StartTime
    $module = $process.MainModule
    $moduleBase = $module.BaseAddress.ToInt64()
    $handle = [ShelldiverSkillCamera.NativeReader]::OpenProcess(0x10, $false, $ExpectedPid)
    if ($handle -eq [IntPtr]::Zero) {
        throw "Could not open Shelldiver PID $ExpectedPid for memory reads (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    try {
        $lookupCode = Read-GameBytes ($moduleBase + 0x4B1880) 16 'the mapped global lookup code'
        $persistCode = Read-GameBytes ($moduleBase + 0x3C5A3C) 16 'the mapped camera persistence code'
        if ([Convert]::ToHexString($lookupCode) -ne '48895C241048896C2418488974242057' -or
            [Convert]::ToHexString($persistCode) -ne '488B9578040000488B8D38190000E8A1') {
            throw "PID $ExpectedPid has a mapped Shelldiver image that differs from the verified build."
        }
        $previous = Read-SkillCamera
        Start-Sleep -Milliseconds 45
        $current = Read-SkillCamera
    } finally {
        $null = [ShelldiverSkillCamera.NativeReader]::CloseHandle($handle)
    }

    if ($process.HasExited -or $process.StartTime -ne $startTime) {
        throw "Shelldiver PID $ExpectedPid changed during the camera read."
    }
    if ($previous.ui_zoom_factor_goal -ne 1.0 -or $current.ui_zoom_factor_goal -ne 1.0) {
        throw 'The resident skill map is not at stock 1× zoom. Its global stores a zoom target, so exact displayed zoom is unavailable.'
    }
    foreach ($axis in 'x','y') {
        $offset = 'skill_ui_' + $axis + 'offset'
        $shake = "shake_$axis"
        if ([Math]::Abs($previous[$offset] - $current[$offset]) -gt 0.1 -or
            [Math]::Abs($previous[$shake]) -gt 0.1 -or [Math]::Abs($current[$shake]) -gt 0.1) {
            throw 'The resident skill map camera is still moving or shaking.'
        }
    }

    [pscustomobject]@{
        pid = $ExpectedPid
        centerX = 1536 + [Math]::Round($current.skill_ui_xoffset)
        centerY = 1600 + [Math]::Round($current.skill_ui_yoffset)
        zoom = 1.0
    }
} finally {
    $process.Dispose()
}
