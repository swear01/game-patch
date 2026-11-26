# Outhold 本機遊玩橋接

適用於 Windows Steam 版 Outhold（App 3767740）。支援的原版 PCK SHA-256 為 `74F975C009F37C6C7424961A9074A2ED1DA65912A174D5DC6C89A1DCFD79ADDA`。需要 Node.js 24 和 PowerShell 7.4 以上。

`achievement_cli.gd` 是遊戲內橋接，`achievement-plan.json` 是可修改的單局範例。橋接透過原版遊戲入口選關、配置、購買和結算。若要先查看遊戲介面，可在啟動前將計畫改為 `[]`。

1. 退出正式遊戲。在本目錄建立 `game-achievement-clock`，從自有 Steam 安裝複製遊戲執行檔和同目錄的相依 DLL 至該目錄，並將複製的執行檔命名為 `outhold_native_play.exe`。
2. 用原版 PCK 或經校驗的原版備份作為輸入，重建測試副本。
3. 啟動副本。須加速時，可在 OpenSpeedy 選擇 `outhold_native_play.exe`。遊戲時鐘倍率和密集戰鬥實際速度可能不同。

```powershell
$stock = '<Steam 安裝目錄>/Outhold/outhold_windows.pck'
node .\pack.cjs build $stock .\game-achievement-clock\outhold_native_play.pck .\achievement_cli.gd
.\Start-AchievementPlay.ps1
```

實際 PCK 檔名可從 Steam 安裝目錄確認。組包程式只建立指定的新檔案。退出測試副本後，Steam 原版仍可從正式目錄啟動。若需要保留正式遊戲進度，先備份本機存檔再開同遊戲的測試副本。

`node .\steam-achievements.cjs '<Steam 目錄>/appcache/stats'` 只讀本機 Steam 成就快取。此前測試記錄了遊戲內和 Steam 快取中的 15/15 成就。本目錄只收錄可自行重建的橋接、工具和範例計畫。

公開版的 Node.js 24 和 PowerShell 腳本均通過語法檢查。重建需要符合上述雜湊的原版 PCK。
