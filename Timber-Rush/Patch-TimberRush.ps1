#Requires -Version 7.2
param(
    [ValidateSet('Stage', 'Install', 'Restore')]
    [string]$Action = 'Stage',

    [string]$GameDirectory = 'E:\SteamLibrary\steamapps\common\Timber Rush\TimberRush_Windows',

    [string]$StageDirectory,

    [string]$CecilPath = (Join-Path $env:USERPROFILE '.nuget\packages\mono.cecil\0.11.6\lib\netstandard2.0\Mono.Cecil.dll')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$originalHash = '554DEA1074ADCA8053D58615B8F1B1BC009BDD1CF510955BC2A3EA0A4D1362C3'
$gameRoot = (Get-Item -LiteralPath $GameDirectory).FullName
$managed = Join-Path $gameRoot 'Timber Rush_Data\Managed'
$gameAssembly = Join-Path $managed 'Assembly-CSharp.dll'
$gameExe = Join-Path $gameRoot 'Timber Rush.exe'
$backup = "$gameAssembly.timber-rush-auto-upgrade-original"
$helperName = 'TimberRushAutoUpgrade'
$helperAssembly = Join-Path $managed "$helperName.dll"

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-GameClosed {
    $running = Get-Process -Name 'Timber Rush' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $gameExe }
    if ($running) {
        throw 'Close Timber Rush before changing its installed assemblies.'
    }
}

function Assert-Original([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Sha256 $Path) -ne $originalHash) {
        throw "Timber Rush Steam build 26525431 original SHA-256 mismatch: $Path"
    }
}

function Open-Assembly([string]$Path) {
    $reader = [Mono.Cecil.ReaderParameters]::new()
    $reader.InMemory = $true
    [Mono.Cecil.AssemblyDefinition]::ReadAssembly($Path, $reader)
}

function Get-ChooseMethod($Assembly) {
    $type = $Assembly.MainModule.GetType($helperName)
    if (-not $type -or $Assembly.Name.Name -ne $helperName) {
        throw 'Invalid Timber Rush auto-upgrade companion assembly.'
    }
    $methods = @($type.Methods | Where-Object {
        $_.Name -eq 'Choose' -and $_.IsStatic -and $_.IsPublic -and
            $_.Parameters.Count -eq 8 -and $_.ReturnType.FullName -eq 'System.Int32'
    })
    if ($methods.Count -ne 1) {
        throw 'Missing expected TimberRushAutoUpgrade.Choose method.'
    }
    $expectedParameters = @(
        'System.Collections.Generic.List`1<StatModifier>',
        'Stats',
        'System.Collections.Generic.HashSet`1<StatType>',
        'System.Int32&',
        'System.Nullable`1<StatRarity>',
        'System.Int32',
        'System.Int32',
        'System.Func`5<System.Double,System.Collections.Generic.List`1<StatModifier>,System.Nullable`1<StatRarity>,System.Int32,StatModifier>'
    )
    for ($i = 0; $i -lt $expectedParameters.Length; $i++) {
        if ($methods[0].Parameters[$i].ParameterType.FullName -ne $expectedParameters[$i]) {
            throw "Unexpected parameter $i on TimberRushAutoUpgrade.Choose."
        }
    }
    $methods[0]
}

function Test-GameHook([string]$Path) {
    $assembly = Open-Assembly $Path
    try {
        $testStats = $assembly.MainModule.GetType('TestStats_Dev')
        if (-not $testStats) {
            return $false
        }
        $candidates = @($testStats.Methods | Where-Object Name -eq 'AutoSelect')
        if ($candidates.Count -ne 1) {
            return $false
        }
        $calls = @($candidates[0].Body.Instructions | Where-Object {
            $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Call -and
                $_.Operand.DeclaringType.FullName -eq $helperName -and $_.Operand.Name -eq 'Choose'
        })
        $calls.Count -eq 1 -and $calls[0].Operand.Parameters.Count -eq 8 -and
            $calls[0].Operand.DeclaringType.Scope.Name -eq $helperName
    } finally {
        $assembly.Dispose()
    }
}

function Write-PatchedAssembly([string]$Original, [string]$Helper, [string]$Output) {
    $game = Open-Assembly $Original
    $companion = Open-Assembly $Helper
    try {
        $module = $game.MainModule
        $testStats = $module.GetType('TestStats_Dev')
        $autoSelect = $testStats.Methods | Where-Object Name -eq 'AutoSelect'
        $nativeBanishReplacement = $testStats.Methods | Where-Object Name -eq 'GenerateUniqueModifier'
        $updateBanishText = $testStats.Methods | Where-Object Name -eq 'UpdateBanishText'
        $call = @($autoSelect.Body.Instructions | Where-Object {
            $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Call -and
                $_.Operand.FullName -eq 'System.Int32 TestStats_Dev::ChooseModifierIndex()'
        })
        if ($call.Count -ne 1 -or $call[0].Previous.OpCode.Code -ne [Mono.Cecil.Cil.Code]::Ldarg_0) {
            throw 'Could not verify the original AutoSelect call site.'
        }

        $fields = @{}
        foreach ($field in $testStats.Fields) {
            $fields[$field.Name] = $field
        }

        $func = [Mono.Cecil.TypeReference]::new('System', 'Func`5', $module, $module.TypeSystem.CoreLibrary)
        $delegateType = [Mono.Cecil.GenericInstanceType]::new($func)
        foreach ($parameter in $nativeBanishReplacement.Parameters) {
            $delegateType.GenericArguments.Add($parameter.ParameterType)
        }
        $delegateType.GenericArguments.Add($nativeBanishReplacement.ReturnType)
        $delegateCtor = [Mono.Cecil.MethodReference]::new('.ctor', $module.TypeSystem.Void, $delegateType)
        $delegateCtor.HasThis = $true
        $delegateCtor.Parameters.Add([Mono.Cecil.ParameterDefinition]::new($module.TypeSystem.Object))
        $delegateCtor.Parameters.Add([Mono.Cecil.ParameterDefinition]::new($module.TypeSystem.IntPtr))

        # Use the game's local types in the call signature so the game never references itself.
        $chooseMethod = Get-ChooseMethod $companion
        $companionType = $module.ImportReference($chooseMethod.DeclaringType)
        $choose = [Mono.Cecil.MethodReference]::new($chooseMethod.Name, $module.TypeSystem.Int32, $companionType)
        foreach ($parameterType in @(
            $fields['currentModifiers'].FieldType
            $fields['stats'].FieldType
            $fields['banishedStats'].FieldType
            [Mono.Cecil.ByReferenceType]::new($fields['banishesRemaining'].FieldType)
            $autoSelect.Parameters[1].ParameterType
            $fields['pendingLevelStacks'].FieldType
            $module.TypeSystem.Int32
            $delegateType
        )) {
            $choose.Parameters.Add([Mono.Cecil.ParameterDefinition]::new($parameterType))
        }

        $il = $autoSelect.Body.GetILProcessor()
        $site = $call[0]
        $instructions = @(
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fields['currentModifiers'])
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fields['stats'])
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fields['banishedStats'])
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldflda, $fields['banishesRemaining'])
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fields['pendingLevelStacks'])
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_3)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Ldftn, $nativeBanishReplacement)
            $il.Create([Mono.Cecil.Cil.OpCodes]::Newobj, $delegateCtor)
        )
        foreach ($instruction in $instructions) {
            $il.InsertBefore($site, $instruction)
        }
        $site.Operand = $choose
        $loadThis = $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
        $il.InsertAfter($site, $loadThis)
        $il.InsertAfter($loadThis, $il.Create([Mono.Cecil.Cil.OpCodes]::Call, $updateBanishText))

        $writer = [Mono.Cecil.WriterParameters]::new()
        $writer.DeterministicMvid = $true
        $writer.Timestamp = 0
        $game.Write($Output, $writer)
    } finally {
        $companion.Dispose()
        $game.Dispose()
    }
}

function Build-Helper([string]$Original, [string]$Output) {
    $dotnet = (Get-Command dotnet -CommandType Application | Select-Object -First 1).Source
    $sdkRoot = Join-Path (Split-Path -Parent $dotnet) 'sdk'
    $compiler = Get-ChildItem -LiteralPath $sdkRoot -Directory |
        Sort-Object -Property { $_.Name.Split('-')[0] -as [version] } -Descending |
        ForEach-Object { Join-Path $_.FullName 'Roslyn\bincore\csc.dll' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if (-not $compiler) {
        throw 'A .NET SDK with the Roslyn compiler is required.'
    }

    $references = @('mscorlib.dll', 'netstandard.dll', 'System.dll', 'System.Core.dll', 'UnityEngine.dll', 'UnityEngine.CoreModule.dll') |
        ForEach-Object { '/reference:' + (Join-Path $managed $_) }
    $source = Join-Path $PSScriptRoot "$helperName.cs"
    & $dotnet exec $compiler /nologo /noconfig /nostdlib /target:library /optimize+ /deterministic "/out:$Output" "/reference:$Original" @references $source | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'Timber Rush auto-upgrade companion compilation failed.'
    }
}

if (-not (Test-Path -LiteralPath $CecilPath -PathType Leaf)) {
    throw "Mono.Cecil 0.11.6 was not found: $CecilPath"
}
Add-Type -Path (Get-Item -LiteralPath $CecilPath).FullName

if ($Action -eq 'Stage') {
    $original = if (Test-Path -LiteralPath $backup -PathType Leaf) { $backup } else { $gameAssembly }
    Assert-Original $original

    if ($StageDirectory) {
        $stage = [IO.Directory]::CreateDirectory($StageDirectory).FullName
        if (Get-ChildItem -LiteralPath $stage -Force | Select-Object -First 1) {
            throw "The staging directory must be empty: $stage"
        }
    } else {
        $stage = [IO.Directory]::CreateTempSubdirectory('TimberRushAutoUpgrade-').FullName
    }
    $stagedGame = Join-Path $stage 'Assembly-CSharp.dll'
    $stagedHelper = Join-Path $stage "$helperName.dll"
    $manifestPath = Join-Path $stage 'hashes.json'
    try {
        Build-Helper $original $stagedHelper
        Write-PatchedAssembly $original $stagedHelper $stagedGame
        if (-not (Test-GameHook $stagedGame)) {
            throw 'The staged game assembly is missing the verified auto-upgrade hook.'
        }
        @{
            original = $originalHash
            patched = Get-Sha256 $stagedGame
            helper = Get-Sha256 $stagedHelper
        } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
    } catch {
        foreach ($path in @($manifestPath, $stagedGame, $stagedHelper)) {
            [IO.File]::Delete($path)
        }
        throw
    }
    $stage
    return
}

Assert-GameClosed

if ($Action -eq 'Restore') {
    if ((Get-Sha256 $gameAssembly) -ne $originalHash) {
        Assert-Original $backup
        if (-not (Test-GameHook $gameAssembly)) {
            throw 'The game assembly is neither the supported original nor a Timber Rush auto-upgrade patch.'
        }
        $restoreCopy = "$gameAssembly.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::Copy($backup, $restoreCopy)
            Assert-Original $restoreCopy
            [IO.File]::Replace($restoreCopy, $gameAssembly, [NullString]::Value)
        } finally {
            [IO.File]::Delete($restoreCopy)
        }
        Assert-Original $gameAssembly
    }
    if (Test-Path -LiteralPath $helperAssembly -PathType Leaf) {
        $companion = Open-Assembly $helperAssembly
        try {
            $null = Get-ChooseMethod $companion
        } finally {
            $companion.Dispose()
        }
        [IO.File]::Delete($helperAssembly)
    }
    'Restored the original Timber Rush assembly.'
    return
}

if (-not $StageDirectory) {
    throw 'Install requires the directory returned by Stage.'
}
$stage = (Get-Item -LiteralPath $StageDirectory).FullName
$stagedGame = Join-Path $stage 'Assembly-CSharp.dll'
$stagedHelper = Join-Path $stage "$helperName.dll"
$manifest = Get-Content -LiteralPath (Join-Path $stage 'hashes.json') -Raw | ConvertFrom-Json
if ($manifest.original -ne $originalHash -or $manifest.patched -ne (Get-Sha256 $stagedGame) -or
    $manifest.helper -ne (Get-Sha256 $stagedHelper) -or -not (Test-GameHook $stagedGame)) {
    throw 'The staged files could not be verified. Run Stage again.'
}
$companion = Open-Assembly $stagedHelper
try {
    $null = Get-ChooseMethod $companion
} finally {
    $companion.Dispose()
}

$installedHash = Get-Sha256 $gameAssembly
$hasBackup = Test-Path -LiteralPath $backup -PathType Leaf
if ($hasBackup) {
    Assert-Original $backup
}
if ($installedHash -ne $originalHash -and ($installedHash -ne $manifest.patched -or -not $hasBackup)) {
    throw 'The installed assembly differs from the supported build or staged patch. Restore the previous patch first if applicable.'
}
$hasHelper = Test-Path -LiteralPath $helperAssembly -PathType Leaf
if ($hasHelper -and (Get-Sha256 $helperAssembly) -ne $manifest.helper) {
    throw 'The installed companion differs from the staged one. Restore the previous patch first if applicable.'
}

$gameCopy = "$gameAssembly.$([guid]::NewGuid().ToString('N')).tmp"
$helperCopy = "$helperAssembly.$([guid]::NewGuid().ToString('N')).tmp"
$movedHelper = $false
try {
    if (-not $hasHelper) {
        [IO.File]::Copy($stagedHelper, $helperCopy)
        if ((Get-Sha256 $helperCopy) -ne $manifest.helper) {
            throw 'The companion copy failed SHA-256 verification.'
        }
        [IO.File]::Move($helperCopy, $helperAssembly)
        $movedHelper = $true
    }
    if ($installedHash -eq $originalHash) {
        [IO.File]::Copy($stagedGame, $gameCopy)
        if ((Get-Sha256 $gameCopy) -ne $manifest.patched) {
            throw 'The patched game assembly copy failed SHA-256 verification.'
        }
        if ($hasBackup) {
            [IO.File]::Replace($gameCopy, $gameAssembly, [NullString]::Value)
        } else {
            [IO.File]::Replace($gameCopy, $gameAssembly, $backup)
        }
    }
} catch {
    if ($movedHelper -and (Get-Sha256 $gameAssembly) -eq $originalHash) {
        [IO.File]::Delete($helperAssembly)
    }
    throw
} finally {
    [IO.File]::Delete($gameCopy)
    [IO.File]::Delete($helperCopy)
}

Assert-Original $backup
if ((Get-Sha256 $gameAssembly) -ne $manifest.patched -or (Get-Sha256 $helperAssembly) -ne $manifest.helper) {
    throw 'The installed auto-upgrade patch failed SHA-256 verification.'
}
'Installed the Timber Rush auto-upgrade patch and verified the original backup.'
