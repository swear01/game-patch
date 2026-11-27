# Shelldiver metadata extraction

The generators read a player's original Steam files and recreate metadata for the native controller. Run them locally before installing the patch, or use an unmodified executable preserved before installing the loader. The generators leave the game files untouched and write three JSON files to the chosen output directory.

## Run

Use PowerShell 7, Node.js, and Microsoft's `dumpbin.exe` from Visual Studio C++ Build Tools. This workflow was verified with Node.js 24.19.0 and MSVC 14.44.35207. Start in a Visual Studio Developer PowerShell with `dumpbin.exe` on PATH, or supply its absolute path with `-Dumpbin`.

```powershell
./Build-ShelldiverMetadata.ps1 -GameDirectory 'C:/Path/To/Steam/Shelldiver' -OutputDirectory ./generated
```

If the installed executable already loads a mod, add `-StockExecutable 'C:/Path/To/Original/Shelldiver.exe'`. The price extractor checks the executable before disassembly and consumes the generated skill layout. Obtain stock inputs from your own Steam installation or an earlier local copy.

| Supported Steam build 23898569, game v1.0.2.300.020 | SHA-256 |
| --- | --- |
| `data.win` | `4b4f08b6c85fd3852a08bccdbb0d6621cc614225f9f804df6afe79258e8c0506` |
| Unmodified `Shelldiver.exe` | `62599f01a4ce4b8946fcc38827e6364539e31abbed99b0828112e670b0c3925e` |

## Outputs

| File | Original source and verification |
| --- | --- |
| `ShelldiverTerrain.original.json` | `data.win` ROOM records, the `tl_main` tile layer, and BGND tile dimensions. The decoder writes solid/open occupancy only. Across all 12 ocean rooms, all 47,440 cells and the complete file match the runtime reference. |
| `skill-layout.original.json` | `data.win` placements in `rm_skill_tree`, the object name table, and stock arrow geometry. Extracts 241 nodes and 270 arrows. One arrow endpoint remains unresolved by placement matching and stays unresolved. |
| `skill-prices.original.json` | Unmodified YYC executable disassembled with `dumpbin.exe`, matched to the generated layout. Extracts 228 constant-price nodes covering 766 ranks, and base values for 11 nodes with conditional prices. Two singleton entries remain unsupported by static price extraction. |

The pinned-build generator reproduced all three original runtime JSON files byte for byte. The wrapper checks the input and output SHA-256 values. `Export-ShelldiverTerrain.mjs` uses the pinned ROOM layout and reads the GameMaker 2024.2+ RLE format documented in [UndertaleModTool's room model](https://github.com/UnderminersTeam/UndertaleModTool/blob/master/UndertaleModLib/Models/UndertaleRoom.cs). Running the generators does not require UndertaleModTool.

Conditional prices need the current game configuration. The Steam build verified Bubble Size II at two ranks of 2,000 obsidian each. The two unsupported singletons were the starting Submarine rank and Hammock Repair. The native game verified the starting rank and the hammock's 10Q shell purchase after the five branch finals. The original save verified 800 total ranks. These limited numeric rules can be recorded in controller code with their provenance. The complete generated files remain local inputs to the controller. Steam binaries, textures, room assets, and saves stay in their original or private backup locations.
