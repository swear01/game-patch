// Opt-in IPC for the local Fragile test. The game still handles every click,
// challenge rule, score, and save through its own events.
_MinutescapeChallengeCliTick(initialising = false) {
    if (this._minutescapeCli === undefined) {
        this._minutescapeCli = null;
        try {
            if (!this.IsNWjs()) return;
            const fs = require("fs");
            const path = require("path");
            const data = (self["process"] || nw["process"]).env.LOCALAPPDATA;
            if (!data) return;
            const profile = path.join(data, "Minutescape", "User Data", "Default");
            const control = path.join(profile, "minutescape-fragile-test.json");
            if (!fs.existsSync(control)) return;
            const request = JSON.parse(fs.readFileSync(control, "utf8"));
            if (!/^[a-f0-9]{24}$/.test(request.session) || !Number.isInteger(request.runs)
                || request.runs < 1 || request.runs > 5) return;
            const trace = path.join(profile, `minutescape-fragile-${request.session}.jsonl`);
            const modes = ["stuck", "story", "fragile", "noAbilities"];
            const mode = modes.includes(request.mode) ? request.mode : "fragile";
            const nextMode = ["stuck", "noAbilities"].includes(request.nextMode) && request.nextMode !== mode
                ? request.nextMode : null;
            const goal = Number.isInteger(request.goal) && request.goal >= 120 && request.goal <= 600 ? request.goal : 120;
            this._minutescapeCli = { fs, control, trace, mode, nextMode, goal, runs: request.runs, index: 0,
                phase: "load", disabled: false, next: 0, frames: 0 };
            fs.appendFileSync(trace, JSON.stringify({ event: "ready", initialising, mode }) + "\n");
        } catch (error) {
            console.error("Minutescape challenge test setup failed", error);
        }
    }
    const cli = this._minutescapeCli;
    if (!cli || cli.disabled || initialising || this.IsSuspended()) return;
    ++cli.frames;
    const now = performance.now();
    if (now < cli.next) return;
    cli.next = now + 180;
    const emit = (event, fields = {}) => cli.fs.appendFileSync(cli.trace,
        JSON.stringify({ event, mode: cli.mode, index: cli.index, ...fields }) + "\n");
    try {
        if (!cli.fs.existsSync(cli.control)) {
            cli.disabled = true;
            return;
        }
        const layout = this.GetMainRunningLayout();
        if (!layout || this.IsLayoutFirstTick() || this._NeedsHandleSaveOrLoad()
            || this.GetLayoutManager().IsPendingChangeMainLayout()) return;
        const instance = name => this.GetObjectClassByName(name)?.GetInstances()[0];
        const variables = this.GetEventSheetManager();
        const value = sid => variables.GetEventVariableBySID(sid)?.GetValue();
        const visible = name => layout.GetLayerByName(name)?.IsVisible();
        const mouse = instance("Mouse")?.GetSdkInstance();
        const storage = instance("LocalStorage")?.GetSdkInstance();
        const busy = storage && (C3.Plugins.LocalStorage.Cnds.IsProcessingGets.call(storage)
            || C3.Plugins.LocalStorage.Cnds.IsProcessingSets.call(storage));
        const click = target => {
            const world = target?.GetWorldInfo();
            if (!mouse || !world?.IsVisible()) return false;
            const box = world.GetBoundingBox();
            const [x, y] = world.GetLayer().LayerToCanvasCss((box.getLeft() + box.getRight()) / 2,
                (box.getTop() + box.getBottom()) / 2);
            const prior = [mouse._mouseXcanvas, mouse._mouseYcanvas, mouse._triggerType, mouse._triggerButton];
            [mouse._mouseXcanvas, mouse._mouseYcanvas, mouse._triggerType, mouse._triggerButton] = [x, y, 0, 0];
            try { mouse.Trigger(C3.Plugins.Mouse.Cnds.OnObjectClicked); }
            finally { [mouse._mouseXcanvas, mouse._mouseYcanvas, mouse._triggerType, mouse._triggerButton] = prior; }
            return true;
        };
        const name = layout.GetName();
        if (name === "Main Menu" && cli.phase === "load" && !busy && value(540273061315122)) {
            const play = this.GetObjectClassByName("txt_mainMenuButtons")?.GetInstances()
                .find(row => row.GetInstanceVariableValue(2) === "play");
            if (click(play)) cli.phase = "prepare";
            return;
        }
        if (name === "Upgrade" && !busy) {
            if (cli.phase === "play" && cli.reached) cli.phase = "settle";
            if (cli.phase === "settle") {
                const reward = this.GetObjectClassByName("dict_challengeMultipliers")?.GetInstances()[0]
                    ?.GetSdkInstance()?.GetDataMap()?.get(cli.mode);
                emit("settled", { best: this.GetObjectClassByName("txt_challengesRecord")?.GetInstances()
                    .find(row => row.GetInstanceVariableValue(1) === cli.mode)?.GetSdkInstance()?.GetText?.(), reward });
                if (cli.index >= cli.runs || cli.reached) {
                    if (!cli.nextMode) {
                        emit("complete");
                        cli.disabled = true;
                        return;
                    }
                    cli.mode = cli.nextMode;
                    cli.nextMode = null;
                    cli.index = 0;
                    cli.reached = false;
                }
                cli.phase = "prepare";
            }
            if (cli.phase === "load") cli.phase = "prepare";
            if (cli.phase !== "prepare") return;
            if (cli.mode === "story") {
                const button = instance("spr_simulateButton")?.GetWorldInfo();
                const keyboard = instance("Keyboard")?.GetSdkInstance();
                if (visible("Black Screen") || !visible("Simulate Button") || !button?.IsVisible() || !keyboard) return;
                const prior = keyboard._triggerWhich;
                keyboard._triggerWhich = 13;
                try { keyboard.Trigger(C3.Plugins.Keyboard.Cnds.OnKey); }
                finally { keyboard._triggerWhich = prior; }
                ++cli.index;
                cli.phase = "entered";
                emit("simulate");
                return;
            }
            if (visible("Challenges")) {
                const button = this.GetObjectClassByName("9p_challengesButton")?.GetInstances()
                    .find(row => row.GetInstanceVariableValue(0) === cli.mode);
                if (click(button)) {
                    ++cli.index;
                    cli.reached = false;
                    cli.phase = "entered";
                    emit("challenge-click");
                }
            } else if (!visible("Black Screen")) {
                const hub = this.GetObjectClassByName("spr_upgradeButtons")?.GetInstances().find(row => row.GetUID() === 459);
                if (!click(hub)) throw new Error("Challenge Hub control unavailable");
            }
            return;
        }
        if (name !== "Dodge" || value(530499771236373) !== (cli.mode === "story" ? "" : cli.mode)
            || (cli.phase !== "entered" && cli.phase !== "play")) return;
        const world = instance("spr_player")?.GetWorldInfo();
        const hp = value(144141474833536), level = value(634217739121904);
        if (cli.phase === "entered" && world && hp > 0) {
            cli.phase = "play";
            emit("start", { hp, level, collision: world.IsCollisionEnabled(), speed: value(243772438063051),
                left: value(477848051505523), right: value(505640545931379) });
        }
        if (cli.phase !== "play") return;
        const clock = this._openSpeedyClock;
        emit("sample", { level, hp, x: world?.GetX(), y: world?.GetY(), frames: cli.frames,
            ticks: this.GetTickCount(), wall: this.GetWallTime(), game: this.GetGameTime(), scale: this.GetTimeScale(),
            perf: now, frame: clock?.frame, audio: this._OpenSpeedyAudioClock(), kind: clock?.kind,
            rate: clock?.rate, calibrated: clock?.calibrationRate, dt: this.GetDt1(),
            background: !!this._minutescapeBackgroundTicking, focused: document.hasFocus(),
            visibility: document.visibilityState, shield: value(468190106749655),
            shieldActive: instance("spr_playerShield")?.GetWorldInfo()?.IsVisible(),
            wave: value(955318864596436), charging: !!value(186150369012403),
            chargeTime: value(708128531638183), chargeDuration: value(719031418869378),
            walls: this.GetObjectClassBySID(253185647818588)?.GetInstances().length });
        const won = cli.mode === "story" && !!value(268593593103345);
        if (won && !cli.reached) {
            cli.reached = true;
            emit("victory", { level, hp });
        } else if (cli.mode !== "story" && !cli.reached && level >= cli.goal && hp > 0) {
            cli.reached = true;
            emit("goal", { level, hp });
        }
        if ((hp <= 0 || won) && visible("Post-Game")) {
            const message = instance("txt_losingSentence")?.GetSdkInstance();
            if (!message || !mouse || C3.Plugins.Text.Cnds.IsRunningTypewriterText.call(message)) return;
            cli.phase = "settle";
            emit(won ? "win-exit" : "loss", { level });
            mouse.Trigger(C3.Plugins.Mouse.Cnds.OnAnyClick);
        }
    } catch (error) {
        cli.disabled = true;
        emit("error", { message: String(error.stack ?? error) });
    }
}
