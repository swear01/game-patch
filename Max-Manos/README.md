# Max Manos

Draw 跳幀實驗把 FingerGun 瞄準更新移到 End Step。實戰時按 F6 循環每 1、5 或 10 次更新繪圖一次，按 F7 記錄測量樣本。效能和玩法的驗證範圍見 [測試紀錄](verified-settings.md)。

## 重建

需要 PowerShell 7、[UndertaleModTool CLI 0.9.2.0](https://github.com/UnderminersTeam/UndertaleModTool/releases/tag/0.9.2.0) 的 Windows 發行版，以及自己安裝中的相容原版 Max Manos `data.win`。透過 Steam 的「瀏覽本機檔案」可找到遊戲資料夾。從儲存庫根目錄執行以下命令。

```powershell
./Max-Manos/Build-MaxManosPatch.ps1 `
  -BaseData 'D:/SteamLibrary/steamapps/common/Max Manos/data.win' `
  -UndertaleModCli 'C:/Tools/UTMT_CLI/UndertaleModCli.exe' `
  -Output 'C:/Temp/max-manos-experimental-data.win'
```

腳本會檢查原版檔案的雜湊，從輸入解出原版 Draw 事件，然後套用 [補丁程式](work/patch_draw.csx) 和 [End Step 邏輯](work/draw_end_step.gml)。輸出放在指定的新檔案。遊戲測試用的安裝副本可在完全關閉遊戲後換入產物，並留一份原版供復原。

| 檔案 | SHA-256 |
| --- | --- |
| 已驗證的原版輸入 | `2de3c6077f0447aab07dc4a0bfe00490d77ca240259d40374affcee24dc3cf9c` |
| 重建產物 | `fb5bfd10c996b2548a5082908402ed310a377b71261fd22bf447530b64c3d4f5` |

用上述原版和 CLI 實際重建後，產物與 2026-10-12 保存的實驗版逐位元相同。原版 `data.win` 為 49,067,590 bytes，其中音訊區段佔 43,662,350 bytes。扣除重建時搬動的索引後，61 個音訊項目的資料一致。重建後整個遊戲資料容器增加 1,536 bytes，其中程式碼區段增加 944 bytes。

`work/audit_draw.csx` 和 `work/audit_draw_patched.csx` 可用同一 CLI 檢查輸入、輸出事件。執行時從本目錄呼叫 `UndertaleModCli load <data.win> --scripts <audit.csx>`，解出的檔案會留在各自的本機分析資料夾。[歷史量測結果](results/) 保留原測試數據。
