# Shelldiver controller

The controller targets Windows x64, PowerShell 7, and Steam app 3862670 build 23898569. It uses a resident Shelldiver bridge to operate the game's controls and reads the original save for receipts. The game window stays available while it runs. The capture and skill camera helpers verify both the Shelldiver process and its executable before reading. They accept Steam libraries on any drive.

## Set up the local profile

1. Install Shelldiver through Steam. Build and install the game-specific resident bridge using the instructions in [native](native/README.md).
2. From the Shelldiver package directory, copy the controller into its runtime path. The bridge and recovery scripts use this exact profile name.

   ```powershell
   $runtimeRoot = Join-Path $env:LOCALAPPDATA 'ShelldiverAutoplay/2026-11-27'
   $controller = Join-Path $runtimeRoot 'autoplay'
   New-Item -ItemType Directory -Path $controller -Force | Out-Null
   Copy-Item -Path './autoplay/*' -Destination $controller
   ```

3. Generate the terrain grid, skill positions, and skill price tables from your own Steam installation. Use the instructions in [metadata](metadata/README.md) and put the three generated JSON files in `$controller`.
4. Start Shelldiver from Steam. Check for a live bridge snapshot, then choose Continue in the game or use the controller's Launch action to advance from the title screen to an existing save.

   ```powershell
   & "$controller/Invoke-Shelldiver.ps1" -Action snapshot
   & "$controller/Invoke-ShelldiverSession.ps1" -Action Launch
   ```

The bridge mailbox is `%LOCALAPPDATA%/ShelldiverAutoplay/2026-11-27/mailbox`. The game maintains its standard save in `%APPDATA%/Shelldiver/save/Game.json`. The controller reports saved balances and rank changes. The capture fallback uses Windows System.Drawing. Optional catch badge recognition requires the Windows English OCR language capability.

## Plan and run

Use a settled island with an existing save. The recorded end-to-end run used an established save and verified ranks 702 through 800 and the original hammock ending. Export the stock catalogue once to support the read-only planner preview. Export removes the current progression state from the catalogue. Actual runs verify the live stock catalogue.

```powershell
& "$controller/Invoke-ShelldiverVerification.ps1" -Action ExportCatalog
& "$controller/Invoke-ShelldiverProgression.ps1" -Action Plan -Profile MaxRanks
& "$controller/Invoke-ShelldiverProgression.ps1" -Action Run -Profile MaxRanks
```

`MaxRanks` targets all 800 ranks. It uses 1200m for fishing and obsidian and selects shallower expeditions for required exclusive materials. It reads the saved inventory's current stack capacity, returns from deep fishing when native inventory confirms full, and uses native submarine refill, conversion, shop, alchemy, and skill tree controls. Stop from a second PowerShell session with `Invoke-ShelldiverSession.ps1 -Action Stop`. Inspect progress without sending input with `Invoke-ShelldiverProgression.ps1 -Action Status`.

After the ranks are complete, activate the original hammock ending from the settled island, then check the recorded rank and ending state.

```powershell
& "$controller/Invoke-ShelldiverEnding.ps1"
& "$controller/Invoke-ShelldiverVerification.ps1" -Action VerifyCompletion
```

`VerifyCompletion` can read an idle island or the post-ending native main menu. It checks 241 live native nodes against all 800 saved ranks and verifies the saved hammock ending and five final branches.

## Package scope

The separately generated JSON contains original room collision grids, skill layout, and stock prices. The stock game executable, data.win, those extracted tables, the player's save, screenshots, and runtime mailbox contents stay on the player's machine. The included verification summary records the completed 800-rank run without the original save, game screenshots, or personal paths.

The controller expects the game-specific resident bridge. OpenSpeedy, generic process tools, loader executables, old experimental builds, and the working game executable are outside this controller package.
