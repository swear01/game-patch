# Kin and Quarry

Steam Windows 版的 Godot 4.5.1 GDScript 相容性調整涵蓋採礦日切換、方塊重用、傷害佇列、音效上限和鏡頭更新。可另外啟用本機控制信箱與自動採礦。OpenSpeedy 3.3.20 修復了保留加速開關時切換倍率可能造成的 QPC 倒退。 [官方 3.3.20](https://github.com/game1024/OpenSpeedy/releases/tag/3.3.20) · [上游問題](https://github.com/game1024/OpenSpeedy/issues/320)

## 安裝與還原

1. 存檔後關閉遊戲。從 Steam 的「管理 → 瀏覽本機檔案」找遊戲目錄。若有 `override.cfg`，先備份到遊戲目錄以外。
2. 複製同資料夾的 `quarry-*.gd` 到遊戲目錄。`quarry-test-input.gd` 只供隔離驗證，可留在工具資料夾。
3. 參考 [override.cfg.example](override.cfg.example)，將 `<game-directory>` 換成遊戲目錄完整路徑並使用正斜線。合併設定至遊戲目錄的 `override.cfg`。已有其他 override 時保留不相干的項目。
4. 從 Steam 啟動並先以 1× 檢查。加速倍率和快捷鍵由 OpenSpeedy 設定。

關閉遊戲後還原備份的 `override.cfg`，或移除本次加入的自動載入與執行緒設定。再刪除本次複製到遊戲目錄的 `quarry-*.gd`。

## 本機控制

建立其他帳號無法寫入的信箱資料夾，將路徑寫入 `%APPDATA%\Godot\app_userdata\Kin and Quarry\quarry-control-path.txt`，再啟動遊戲。也可在啟動遊戲的環境設定 `QUARRY_CONTROL_DIR`。移除設定並重啟即可停止信箱。腳本使用相同目錄與信箱鎖。從本資料夾執行 PowerShell：

~~~powershell
./Invoke-QuarryControl.ps1 -Action status
./Invoke-QuarryControl.ps1 -Action open_save_picker
./Invoke-QuarryControl.ps1 -Action load_slot -Slot 1
./Invoke-QuarryControl.ps1 -Action start_day
./Invoke-QuarryControl.ps1 -Action acknowledge_artifact
./Invoke-QuarryControl.ps1 -Action advance_day
./Invoke-QuarryControl.ps1 -Action save_and_close
& './Auto Mining.ps1'
~~~

載入所需存檔後再開啟 Auto Mining。它透過遊戲現有按鈕確認獎勵並開始下一天，遇到起始地層選擇時由玩家處理。按 Ctrl+C 停止自動循環。測試時使用獨立存檔及控制目錄，設定 `QUARRY_TEST_PROFILE=1` 可讓測試控制信箱停用存檔退出。

## 驗證紀錄

先前正常 Steam 啟動的同日取樣中，25× 設定實測採礦倒數約 22–25×。由 25× 切換 10× 後同一採礦日持續推進，六位礦工移動。渲染中的副本測試在 120× 設定下，五位礦工的倒數推進為 112–116×。30 位礦工的 200× 測試約 38×、14 FPS。實際表現取決於場景和工作量。高倍率的音效節流會省略部分事件聲音。

[experimental-engine](experimental-engine/README.md) 保存另一個 Godot 引擎端實驗。[openspeedy-history](openspeedy-history/README.md) 保存舊版時鐘補丁的來源及授權。
