# Idle Spiral

現有公開版支援 Steam Windows 的 Idle Spiral 3.0.82。遊戲載入 Harmony 修補程式後，由 OpenSpeedy 選擇倍率。完整安裝、還原、第三方授權及測試結果請看原專案的歸檔版本。 [原始碼](https://github.com/swear01/idle-spiral-openspeedy-patch) · [封存 Release](https://github.com/swear01/idle-spiral-openspeedy-patch/releases/tag/archive-2026-10-24)

- `idle-spiral-openspeedy-patch-package.zip` 的 SHA-256 為 `c3de77843bb3592c4cef7a663b934a6e5a692f463974e580b92531d183fe5f39`。
- [Measure-IdleSpiralSpeed.ps1](Measure-IdleSpiralSpeed.ps1) 唯讀取樣自動存檔。用 `-SavePath` 明確指定存檔可覆蓋預設路徑。輸出分開記錄牆鐘、存檔時間戳及遊戲進度。取樣間隔與自動存檔週期會影響精度。
- [early-runtime.patch](early-runtime.patch) 保留早期有差異的 Harmony runtime、載入入口及建置參考。這份歷史截面以 [54e6ad0](https://github.com/swear01/idle-spiral-openspeedy-patch/commit/54e6ad02003495ca696e226038beee57f07699c4) 為基底，原版程式集由玩家本機提供。`GameManaged` 可經 MSBuild 屬性指定。建置結構與正式歸檔版不同。

早期封包的組件與正式歸檔共用多個載入器及第三方相依套件。正式封包與 Unity Doorstop、Harmony、SharpMonoInjector 授權由原 Release 提供。本資料夾保留版本入口、唯讀測量腳本及早期 runtime 差異。
