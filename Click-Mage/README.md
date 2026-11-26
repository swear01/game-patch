# Click Mage 本機控制 API

載入存檔後，在 PowerShell 從本目錄執行 `Invoke-ClickMageControl.ps1`。遊戲程序會在 `%LOCALAPPDATA%\ClickMageControl\<PID>` 收取命令，並在 Unity 主執行緒執行。座標使用遊戲世界的 X、Y，`scan` 可查落地資源、採集點、工廠、燃料入口和交付箱。

| 指令 | 參數 | 行為 |
| --- | --- | --- |
| `status` | 無 | 查遊戲時間、倍率、點擊等級和手持資源 |
| `speed` | `-Multiplier 1..32` | 設定本次遊戲的 Unity 倍率。暫停時遊戲時間仍停止 |
| `render` | `-VSync 0 [-MaxFps 60] [-Borderless]` | 調整垂直同步、畫面更新上限，或切到螢幕原生解析度的無邊框模式 |
| `watch` | `[-X -Y]` 或 `-WatchOff` | 讓遊戲鏡頭跟隨 API 的作業地點，可先指定起始位置 |
| `scan` | `-Kind all\|resources\|nodes\|buildings` | 查目前世界狀態 |
| `catalog` | 無 | 查可用配方、建造費用、方尖碑升級和傳送門各階段需求 |
| `click` | `-X -Y -Count` | 用現有點擊強度和等級操作採集點，每次 1 到 160 下 |
| `collect` / `drop` | `-X -Y -Seconds [-Count]` | 在指定位置按住原版拾取或放下，時間以遊戲秒計。拾取可用 `-Resource` 指定種類 |
| `ship` | `-X -Y -Resource -Count [-From]` | 批次搬運最多 40 件現有資源，每件經過原版手持、放下和收料檢查 |
| `shipbatch` | `-Transfers` | 一次提交 1 到 12 筆搬運，每筆使用 `x`、`y`、`resource`、`count`，可用 `from` 和來源座標限制取料 |
| `shipbatch` | `-Transfers` | 一次提交 1 到 12 筆 `ship`，遊戲逐筆執行並回傳各筆結果 |
| `recipe` | `-TargetId -Recipe` | 選擇機器或商人目前可用的原版配方 |
| `upgrade` | `-Upgrade` | 在方尖碑選定一項可買升級，仍須送入全部材料 |
| `build` | `-Building -X -Y` | 放置已解鎖及購買的藍圖，照原版碰撞和材料規則建造 |
| `save` | 無 | 走原版手動存檔流程 |
| `saves` / `load` | 載入使用 `-SaveCounter [-SaveName]` | 在主選單列出或載入指定存檔 |
| `ending` / `continueending` | 無 | 查結局狀態，或在原版離島選項與結局對話開放時前進一步 |

```powershell
.\Invoke-ClickMageControl.ps1 -Action status
.\Invoke-ClickMageControl.ps1 -Action speed -Multiplier 4
.\Invoke-ClickMageControl.ps1 -Action scan -Kind buildings
```

`-Transfers` 接受一組包含 `x`、`y`、`resource`、`count` 的 PowerShell 雜湊表，可另加 `from` 和來源範圍。每筆搬運的 `index` 從 0 開始。若一筆出錯、手上有剩料或收料口把物品留在地上，批次會停止並保留已執行的回報。

採集使用原版節點門檻。搬運先拾取再放下，由原版判定手持上限、可放位置和容器容量。建造、製作與解鎖照遊戲原本的材料和條件進行。單獨測本 API 的倍率時，先關掉 OpenSpeedy 對 Click Mage 的加速。

OpenSpeedy 可能讓它啟用期間的存檔時間戳排在新存檔之前。從主選單用 `-Action saves` 查編號，再用 `-Action load -SaveCounter <編號>` 載入指定存檔。用 Unity Player 的 `-batchmode` 啟動後，也可以透過這個 API 遊玩。

`ClickMage-Progress.ps1` 可載入搬運、按需求生產、購買和交付階段的 PowerShell 函式。函式依實際存量付材料，原版遊戲收料後才驗證交付和解鎖是否完成。結局回報會在 Unity 實際進入 `EndScreen` 後留下同一場遊戲的證據。

有木炭爐時，生產會先保留鋼錠配方需要的木炭，再補一小批作燃料。木炭爐可以用木頭啟動，其餘有庫存的機器優先用木炭。

有多台機器做同一種材料時，生產先把一輪的工作量分給各台。有現成散料就用一次 `shipbatch` 把不同原料送到多台機器，缺料再按種類集中準備。

`Move-CmMaterial` 搬散料時可用快速批次。需要從箱子取料時，會先拾取同類物品，等到本趟手持上限、交付需求或目的地容量的較小值達成再放下。

`ClickMage-Warehouse.ps1` 的 `Store-CmLoose` 會優先填有空間的同類箱，再使用零庫存的空箱，也可按原版成本增建箱子。首次使用空箱時先放一件，讓遊戲設定材料種類。設定 `$script:ClickMageStowOutput = $true` 後，生產流程會以整手為單位安排入庫，並至少保留 14 件散料。

需要 Windows、PowerShell 7 和 .NET 8 SDK。已驗證 Click Mage v1.5.1，原版組件的 SHA-256 列於安裝腳本。先退出遊戲，再將路徑換成自有 Steam 安裝位置。

```powershell
$game = '<Steam 安裝目錄>/Click Mage'
.\Install-ClickMageControl.ps1 -Action Install -GameDirectory $game
.\Install-ClickMageControl.ps1 -Action Restore -GameDirectory $game
```

第二條指令供需要還原時使用。Steam 更新後若組件雜湊改變，安裝程式會停止。本目錄包括安裝器、補丁程式、遊戲內橋接、PowerShell 用戶端、倉庫與兩段戰役程序。此前遊戲測試確認傳送門完成並進入 `EndScreen`。

公開版的 PowerShell 用戶端與戰役腳本均通過語法檢查。
