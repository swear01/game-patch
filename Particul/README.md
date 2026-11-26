# Particul

Steam Windows 的 Electron renderer 加速與穩定性修補。主模擬時鐘與 Plinko 計時採 50×，穩定版本將主粒子運算收回 5 次、保持 Plinko 50 次，並每畫面只提交一個主粒子命令緩衝。Extractor 去除同格重複佇列，粒子計數在 GPU 提交後讀回。月結自動存檔限每 5 秒真實時間一次。

這份舊版 renderer 只由原檔 SHA-256 辨識。

- 原版 `07F3FE89624CC77407E608917F6E3DE06E1910AA86B46A69E882296956415C88`
- 完整下列流程後 `F32782CA37251E46DF83131CE93C0B6D07A4B7D7A2225FE78AD8A3A3E227AABC`

## 重建

存檔並關閉遊戲。從 Steam 找遊戲目錄，先保存原版 renderer 的 `index.js` 到遊戲目錄以外，再在 PowerShell 跑下列流程。`$game` 換成自己已安裝的 Particul 目錄。先用獨立的遊戲副本驗證時也可用該副本的相同目錄結構。需要獨立 Node.js 做語法檢查。

~~~powershell
$ErrorActionPreference = 'Stop'
$game = '<Particul-directory>'
$bundle = Join-Path $game 'particul-win32-x64/resources/app/.webpack/renderer/main_window/index.js'
if ((Get-FileHash -LiteralPath $bundle).Hash -ne '07F3FE89624CC77407E608917F6E3DE06E1910AA86B46A69E882296956415C88') {
    throw 'Unsupported original Particul renderer'
}
$steps = @(
    @('patch_particle_50x', 'before-50x'),
    @('patch_particle_extractor_queue', 'before-extractor-queue'),
    @('fix_particle_count_readback', 'before-count-readback'),
    @('fix_particle_black_screen', 'before-black-screen-repair'),
    @('reduce_main_particle_steps', 'before-main-step-5x'),
    @('fix_particle_save_flood', 'before-diagnosis-current'),
    @('fix_particle_startup_hang', ''),
    @('skip_particle_negotiation_animation', ''),
    @('skip_slot_price_wheel_animations', ''),
    @('skip_active_slot_price_wheel_animations', '')
)
foreach ($step in $steps) {
    if ($step[1]) {
        $snapshot = "$bundle.$($step[1])-20260904.js"
        if (Test-Path -LiteralPath $snapshot) { throw "Restore stock and preserve or clear the existing stage backup $snapshot first." }
        Copy-Item -LiteralPath $bundle -Destination $snapshot
    }
    & "./source/$($step[0]).ps1" -GameDir $game
}
node --check $bundle
if ($LASTEXITCODE -ne 0) { throw 'Patched renderer failed syntax checking' }
if ((Get-FileHash -LiteralPath $bundle).Hash -ne 'F32782CA37251E46DF83131CE93C0B6D07A4B7D7A2225FE78AD8A3A3E227AABC') {
    throw 'Unexpected patched Particul renderer'
}
~~~

前六步的手動快照是相鄰補丁所需的輸入，後四份腳本建立自己的備份。先處理舊 Slot／Price Wheel 元件，才能重建最後腳本使用的原始雜湊。最後一步處理 Marketplace 實際使用的元件。遊戲沿用既有隨機選取、成本和結果回呼。啟動修補改從本機 IndexedDB 載入，略過啟動時的 Steam Cloud 匯入等待。

還原時關閉遊戲，將保留的原版 `index.js` 放回相同位置，並比對原版雜湊。若 Steam 更新導致版本不同，以對應新版本的 Steam 驗證檔案還原。

本次在隔離副本由上述原版重建，十步各自產出的 SHA-256 均與歷史快照一致，最後的 `node --check` 通過。此前已觀察到原 renderer 在實機重開後能運作。這次重建未另啟動遊戲。
