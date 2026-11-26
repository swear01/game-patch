# Unfair Flips

Steam Windows 版（App ID `3925760`，Unity 2022.3.62f2 / D3D11）的低畫質啟動設定。遊戲使用 Unity 的 `Time.deltaTime` 推進翻幣。Very Low 和 Low 畫質的 Unity 內部 VSync 為 0，較高畫質預設為 1。

1. 關閉遊戲，在 Steam 的遊戲內容開啟「啟動選項」，加入 `-screen-quality Low`。
2. 從 Steam 重開遊戲，再在 OpenSpeedy 針對新遊戲程序開啟倍率。
3. 如要還原，移除該 Steam 啟動選項並重開。若另外設定過個別遊戲的 NVIDIA VSync 覆寫，也可回到 NVIDIA 控制台還原。

原驗證使用 OpenSpeedy 3.3.8。只在 NVIDIA 關閉 VSync 的測試中，1× 與 10× 的翻幣到存檔時間均約 2.12 秒。加入 Low 啟動選項並保留當時的 NVIDIA 覆寫，在 10× 下兩次量得約 0.327 與 0.323 秒。數值包含結算及存檔的開銷，反映該次測量條件。 [Unity 啟動參數](https://docs.unity3d.com/2022.3/Documentation/Manual/PlayerCommandLineArguments.html) · [Unity 對 deltaTime 與 VSync 的說明](https://unity.com/blog/engine-platform/fixing-time-deltatime-in-unity-2020-2-for-smoother-gameplay)
