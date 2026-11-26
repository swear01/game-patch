# Minutescape 巡走、挑戰與背景更新

最終整理於 2026-11-19。重建目標為 Steam App 3327170、build 25433331。

F8 開關自動巡走與自動技能。F9 開關自動開普通關卡。背景會繼續模擬，回到前景恢復繪圖。

巡走提前切過四角。路線優先避開所有碰撞，無法全避時優先避開紫、藍彈。紫彈按原版追蹤轉向預測，藍彈按鎖定倒數和實際衝刺速度預測。在擁擠區找到較空的安全路線後，會沿該路線脫離，並持續判斷新的碰撞風險。

一般關卡在護盾接近滿電時才考慮擋紅彈，盾不足時留給紫、藍彈。Fragile 的紅彈可致命，也會用盾。盾鬆開才會按原版機制回充。Stuck 保持原地，護盾優先擋更急的藍彈。震波會等護盾對付不了當前彈群，且血量已下滑或預估連續受擊會消耗大量生命時才蓄力。Broken L.A.B. 保留禁技能，靠預測彈道走位。

OpenSpeedy 的設定只協助估算工作預算。加速步進仍使用 OpenSpeedy 實際改變的時鐘。正式存檔的 10× 取樣在前景和失焦背景均接近 10× 基礎模擬速率。關卡計時也受原版遊戲內倍率及受擊慢動作影響。

解壓後，從 SHA-256 為 `BE9F864E19141B337B2F43CD1E4F54A7632BACDA5BB310E86850A986AAF43119` 的原版建立候選封包。路徑請依本機位置調整。

```powershell
python minutescape_background_packager.py build package.nw.openspeedy-stock-direct package.nw.candidate
```

正式安裝封包的 SHA-256 為 `91EE7782B80199AB54660F6FA3D2E7544C06538A59075C0F53979F4852041C88`。遊戲完全退出後，`python minutescape_background_packager.py restore package.nw package.nw.openspeedy-stock-direct` 會以 `package.nw.before-late-wave` 回到上一個補丁版（SHA-256 以 `05DEA2D0` 開頭）。由該版重新套用時，以 `upgrade` 取代 `restore`。原版另存在 `package.nw.openspeedy-stock-direct`。

本機測試入口只在遊戲啟動時讀到有效測試請求才作用。Stuck 和 Broken L.A.B. 可在同一次開啟後依序測試。驗收使用原版關卡入口及結算，紀錄由遊戲自行寫入存檔。

正式存檔的結算紀錄為 Stuck 5:00、Broken L.A.B. 4:54、Fragile 4:22。OpenSpeedy 設定為 10×，失焦的 Stuck 通關局實測基礎模擬約 9.85×。

## 其他可重建版本

使用 Python 3.11 以上。以下各程式皆可用 `build '<原版 package.nw>' '<新的封包路徑>'` 從同一受支援的原版重建。請將輸出放在測試目錄，再退出遊戲進行替換並保留原版。

| 程式 | 用途 |
| --- | --- |
| `minutescape_packager.py` | 基礎 OpenSpeedy 時間步進修正 |
| `minutescape_patrol_packager.py` | 沿邊巡走，F8 開關 |
| `minutescape_layout_autofarm_packager.py` | 高倍率步進、自動開局與天賦拖曳修正 |
| `minutescape_refinement_packager.py` | 躲彈巡邊與天賦樹更新 |
| `minutescape_background_packager.py` | 完整的背景更新及挑戰版 |

挑戰 CLI 和技能組包程式亦為完整版本的共用模組。若單獨使用歷史組包入口，需以 `--speed` 和 `--patrol` 指定符合該版本的片段。公開資料保留共用來源和各版獨立片段，由安裝端的原版封包產生新封包。

在 Python 3.12 重建了五個版本。基礎、沿邊、自動刷分與完整背景版皆與既有成品的位元組一致。躲彈巡邊版與它原本的 ZIP 原始碼重新組包結果一致，SHA-256 為 `290B26F63FECFC13A7F2C3A7B02F516DDB6957893E0DDDF37E05EF135B9D7388`。現存的 `package.nw.before-auto-skills` 則是不同的歷史封包。
