# Godot 引擎實驗

[working-tree.patch](working-tree.patch) 是以 [Godot 4.5.1-stable，f62fdbd](https://github.com/godotengine/godot/commit/f62fdbde15035c5576dad93e586201f4d41ef0cb) 為基底的診斷、效能實驗差異。[untracked](untracked/) 的兩個額外標頭需按相對路徑放到引擎原始碼，其中一個屬於 vendored Jolt 的測量程式。

在獨立的原版引擎 checkout 中，先用 `git apply --check <path>/working-tree.patch` 檢查，再執行 `git apply <path>/working-tree.patch` 並放入兩個標頭。這份歷史差異保留引擎事件、物理、渲染等工作的分析掛點。遊戲端安裝請見上一層 README。引擎實驗尚未通過完整遊戲驗證。

[Godot MIT 授權](LICENSE-Godot.txt) · [Jolt 授權](LICENSE-Jolt.txt)
