# Sixty Four

Steam Windows 版 Sixty Four 1.2.1（App ID `2659900`）的本機遊戲 API、時鐘修正與音效防護。使用 PowerShell 7+ 和獨立 Node.js 24+。API 和 CLI 無需 npm 套件。

## 安裝與還原

存檔後關閉遊戲。從 Steam 找到含 `sixtyfour.exe` 與 `resources/app` 的 `win-unpacked` 目錄，將下例的路徑換成本機路徑。

~~~powershell
./install.ps1 -GameDir '<path-to-win-unpacked>'
# 之後從 Steam 開啟遊戲，再執行
node ./sixtyfour.mjs health
node ./sixtyfour.mjs state
node ./sixtyfour.mjs catalog
~~~

安裝會備份原版 `main.js`、`game.js` 和現有本機遊戲資料，並將版本雜湊寫到 `installation.json`。備份與 `bridge-config.json` 留在本機。同資料夾的 CLI 讀取自動產生的配置。安裝與還原會檢查所用檔案。關閉遊戲後執行 `./uninstall.ps1` 還原原版程式，保留目前存檔及備份。舊安裝可以用 `./install-clock-fix.ps1` 套用時鐘修正，或用 `./install-api-isolation.ps1` 升級橋接。

### 選用原生時鐘隔離

此模式以已驗證的 OpenSpeedy 3.3.8 `speedpatch64.dll` 雜湊為準。編譯本機 x64 helper 後才能啟用：

~~~powershell
./build-guard.ps1
./openspeedy-guard.exe --self-test --speedpatch '<OpenSpeedy-directory>/speedpatch64.dll'
./install.ps1 -GameDir '<path-to-win-unpacked>' -EnableSpeedControl -OpenSpeedyDir '<OpenSpeedy-directory>'
~~~

已安裝時用 `./install-api-isolation.ps1 -EnableSpeedControl -OpenSpeedyDir '<OpenSpeedy-directory>'`。OpenSpeedy 僅選取遊戲程序。保持獨立 Node gateway 的時鐘為正常速度。遊戲啟用加速後，模擬量由 `state.data.speed` 回報，設定倍率與重負載下的實際倍率可能不同。若官方 DLL 雜湊不符，安裝會停止。 [OpenSpeedy 3.3.8](https://github.com/game1024/OpenSpeedy/releases/tag/3.3.8)

## API 與 CLI

HTTP 固定監聽 `127.0.0.1`，預設埠 `6464`。`GET /health` 免驗證，其餘請求用本機生成的 Bearer token。`GET /state`、`GET /catalog`、`GET /openapi.json` 為唯讀入口，`POST /actions` 接受 `{action,args}`。寫入支持 `place`、`interact`、`remove`、`save`、`resume`，交由原版資源及放置規則處理。

~~~powershell
node ./sixtyfour.mjs interact 0 7 --hold-ms 1000
node ./sixtyfour.mjs save
node ./sixtyfour.mjs session
~~~

`session` 使用一行 JSON 一個指令，例如 `{"id":1,"argv":["state"]}`。保留同一個 stdin 連線即可接著送下一行。用 `client.mjs` 的 `createClientFromConfig()` 可直接在 Node 程式重用連線。`example-agent.mjs` 預設只列計畫，`--act` 會執行一次補料。

逾時後應先重讀狀態再做下一次寫入，因已開始的遊戲動作可能繼續完成。原版動畫會影響資源到帳時間。`save` 確認本機存檔寫入，Steam Cloud 只回報收到寫入請求。

## 驗證

~~~powershell
node --test ./client.test.mjs ./cli.test.mjs ./renderer-adapter.test.cjs ./bridge-main.test.cjs ./bridge-gateway.test.cjs ./clock-fix.test.cjs ./simulation-clock.test.cjs ./speed-control.test.cjs ./audio-guard.test.cjs
~~~

指定本機同版本原版檔案後，120 個 Node 測試全數通過。將 `SIXTYFOUR_ORIGINAL_GAME_JS` 和 `SIXTYFOUR_GAME_JS` 設為原版 `game.js`，並將 `SIXTYFOUR_GAME_SCRIPTS` 設為同版本遊戲的腳本目錄。已驗證 DLL 的 x64 helper 另通過 38 個自測。比對過的安裝中三個橋接模組差異只涉及本機除錯執行入口。本資料夾使用限於固定遊戲動作的發行來源。先前 100× 隔離模式實測兩次一秒長按共約 1.16 秒和 1.03 秒。高負載、模擬積壓和音效節流仍會影響表現。
