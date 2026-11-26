# Cypher Assist

從自有 Windows Steam 安裝重建。助手能讀取目前介面狀態、擷取螢幕，以及透過遊戲的原版輸入欄和按鈕送出答案或要求提示。補丁也設定原生解析度的無邊框模式。

需要 PowerShell 7、.NET 8 SDK 和庫存的 Unity Mono 遊戲組件。支援版本由 `PatchCypher.cs` 及 `patch.ps1` 內的原版 `Assembly-CSharp.dll` 和 `globalgamemanagers` SHA-256 判定。

退出遊戲，在本目錄執行以下指令，將遊戲目錄換成 Steam 顯示的安裝位置。

```powershell
$game = '<Steam 安裝目錄>/Cypher'
.\patch.ps1 -Action install -GameDirectory $game
```

重新開啟遊戲後可用 `.\assist.ps1 status`、`.\assist.ps1 capture -Output '.\cypher.png'`、`.\assist.ps1 type -Answer '<你的解答>'`、`.\assist.ps1 submit -Answer '<你的解答>'` 或 `.\assist.ps1 hint`。輸出只保存在本機指定的位置。

要還原先退出遊戲，再執行 `.\patch.ps1 -Action restore -GameDirectory $game`。還原需要安裝留下的原版備份。

公開版的 .NET 8 補丁器建置通過，兩支 PowerShell 腳本均通過語法檢查。
