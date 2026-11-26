# Minimalism 自動測試

腳本讀取自有 Windows Steam 版的 GameMaker 資料，建立獨立測試副本。它用左右和跳躍指令操作，由原版遊戲判定碰撞、拾取、死亡及過關。需要 Python 3.10 以上、NumPy 和 UndertaleModCli。原始紀錄沒有保存 Steam build ID，請以同版執行檔和 `data.win` 建立副本。

```powershell
python -m pip install numpy
python .\parallel_playtest.py --game '<Steam 安裝目錄>/Minimalism/Minimalism.exe' --umt '<工具目錄>/UndertaleModCli.exe' --work '.\playtest-data'
```

左上視窗從第 1 關開始，其餘三個視窗從第 8、16、24 關測試。預設 5×，每次即時搜尋有 2.5 秒預算。畫面顯示 `PLANNING` 時正在對照真實位置與路線。可用 `--speed 1` 做原速對照，或用 `--plan-timeout` 和 `--planning-workers` 調整搜尋。加入 `--steam-achievements` 會讓主流程保留原版遊戲的 Steam 成就回報。

可用 `plan_campaign.py` 依測試副本輸出的 `rooms.json` 生成候選路線。測試日誌會記錄真實拾取、死亡、過關和結局。已通過的路線可放入 `--verified` 指定的可寫目錄，候選路線用 `--cache` 載入。這些路線及房間匯出資料均在本機生成。

`wait32.c` 是可選的等待輔助程式。可用 32 位元 Windows C 編譯器建成 `minimalism_wait32.dll` 放在腳本旁，例如 `i686-w64-mingw32-gcc -shared -O2 -o minimalism_wait32.dll wait32.c`。測試腳本偵測到它才會使用，未編譯時仍可執行。

此前完整測試記錄 31 關通關、132 次原版符號拾取和結局，且 Steam 客戶端當時同步 165 項成就。公開資料保留程式與測試方法。

公開版的 Python 檔案均通過語法檢查。關卡和結局的結果來自此前使用正式遊戲副本的測試。
