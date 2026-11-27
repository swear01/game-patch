# Timber Rush Auto Upgrade

適用於 Steam Windows 版 `26525431`（App ID `4298880`）。用遊戲原本的 Auto Upgrade 開關。升級和寶箱都會依當局收益選牌，收益接近時偏向高稀有度，包含 Mythical。

預設目標是單局木材量。開局給 Luck、寶箱與經驗較高權重，之後偏向傷害和木材收益。以實際傷害占比調整玩家、伐木工、雷電與熔岩的權重，並預覽卡牌效果，例如比較 Knowledge is Power 在當前等級提供的增益。這套分數是估算，會隨當局牌面和裝備而變。[玩家策略筆記](https://note.com/manatonote/n/n3f6e27f6ae94?hl=en)

自動 Banish 只在升級選牌時使用。每批最多一次，需有可用次數、值得選的另一張牌，以及原版牌池能提供的替代牌。優先移除已達實際上限的卡，18 級起也可移除純金幣卡。30 級起，雷電或熔岩傷害類型若占比低於 2% 且當局未投資該卡，可以放逐該類型的傷害倍率卡。手動 Banish 和自動 Banish 共用原版次數及當局牌池。[官方 Banish 更新](https://steamcommunity.com/app/4298880/allnews/?l=schinese)

## 安裝與還原

需要 PowerShell 7.2+、.NET SDK 和 Mono.Cecil 0.11.6。安裝腳本預設指向本機 Steam 安裝。其他位置可傳入 `-GameDirectory` 指定含 `Timber Rush.exe` 的目錄，或以 `-CecilPath` 指定 Mono.Cecil DLL。

```powershell
$stage = & ./Patch-TimberRush.ps1 -Action Stage
# 關閉遊戲後執行下一行，再從 Steam 打開遊戲。
& ./Patch-TimberRush.ps1 -Action Install -StageDirectory $stage
```

要還原，關閉遊戲後執行 `./Patch-TimberRush.ps1 -Action Restore`。原版備份位於遊戲 `Managed` 目錄的 `Assembly-CSharp.dll.timber-rush-auto-upgrade-original`。Steam 更新或驗證完整性可能覆蓋補丁。套用前會核對原版 SHA-256，遇到不同 build 會停止。

## Steam 成就

使用 OpenSpeedy 時，若遊戲日誌出現 SteamAPI.Init failed，先讓 Timber Rush 在開啟時以原速連上 Steam。重開前備份本機 game_save.json 和 .bak。加速可能使雲端較舊的進度帶有更晚的時間戳，造成遊戲載入舊進度。
