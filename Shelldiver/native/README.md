# Shelldiver native plugin

本機驗證版 `2026.11.27-particle-render-suite`，對應 Windows x64 的 Steam Shelldiver App ID `3862670`、build `23898569`。這是單人玩法的遊戲內遙測和 CLI 控制橋接，透過遊戲內輸入介面操作。版本、遊戲輸入雜湊、依賴與來源雜湊記在 [`inputs.json`](inputs.json)。

## 重建

1. 啟用 Visual Studio 2022 Build Tools 的 C++ x64 工具與 Windows SDK，開啟 x64 Developer PowerShell，再確定 PowerShell 7 能在同一環境呼叫 `cl.exe`。本機以 MSVC 工具組 `14.44.35207` 驗證。
2. 取得指定提交的 YYToolkit 原始碼，保留 `ExamplePlugin/include`，並準備 nlohmann/json `3.12.0` Release 的 `json.hpp` 單一標頭。建置腳本會驗證七個 SDK 檔案與 JSON 標頭的雜湊。[YYToolkit SDK](https://github.com/AurieFramework/YYToolkit/tree/d5cc0078bfbfd5907884ad3fe0b3c6cbaa1c3f54/ExamplePlugin) · [nlohmann/json v3.12.0](https://github.com/nlohmann/json/releases/tag/v3.12.0)
3. 於本目錄用自己的實際依賴路徑執行下列命令。`-SmokeTest` 使用離線測試替身檢查粒子開關、畫面保護與更新心跳。

```powershell
pwsh -NoProfile -File .\Build-ShelldiverNative.ps1 -YYToolkitSource "C:\sdk\YYToolkit-d5cc007" -JsonHeader "C:\sdk\json.hpp" -SmokeTest
```

產物是 `build/ShelldiverAutoplayNative.dll`。建置也保留原始連結檔名 `ShelldiverAutoplayParticleRenderSuite.dll`。實測重建檔與部署檔共差 173 bytes，來自 PE 時間戳和 MSVC 靜態符號配置。109 條含位址差異的指令均核對到相同符號，離線測試通過。兩個 DLL 的雜湊和各節區比對結果收錄於[重建紀錄](rebuild-verification.json)。

## 安裝與驗證

1. 先確認 Steam build 和 `data.win` 雜湊。設定好 Aurie 後，再比對 `inputs.json` 的 `game.executableSha256`，這是已設定載入器的執行檔雜湊。遊戲更新後需重新驗證相容性。
2. 這個 DLL 依賴現有相容的 Aurie 與 YYToolkit 執行環境。已測的版本和雜湊在 `inputs.json`。在遊戲關閉時，把建置產生的 `ShelldiverAutoplayNative.dll` 放到該遊戲的 `mods/aurie/`，以既有的 Shelldiver 模組環境啟動。[Aurie](https://github.com/AurieFramework/Aurie) · [YYToolkit 文件](https://github.com/AurieFramework/YYToolkit/wiki)
3. 啟動後讀取 `%LOCALAPPDATA%/ShelldiverAutoplay/2026-11-27/mailbox/snapshot.json`。同一個遊戲 PID 的 `frame` 持續增加、`inputReady` 為真時，橋接已載入。每個 Windows 使用者的信箱對應一個遊戲程序。

預設維持原版計時與畫面設定。已部署版本的 `60hz` Draw 在實戰測試沒有跳過任何 Draw，因此這版不宣稱畫面節流生效。

關閉遊戲後，從 mods/aurie/ 移出 ShelldiverAutoplayNative.dll，即可卸下這個模組。
