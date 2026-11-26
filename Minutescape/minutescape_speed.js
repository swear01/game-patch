// Substep the native OpenSpeedy clock; never multiply by the GUI's global factor.
_OpenSpeedyAudioClock() {
    try { return 1000 * globalThis.C3_GetAudioContextCurrentTime?.(); }
    catch { return NaN; }
}

async _OpenSpeedyTick(frame) {
    const perf = performance.now();
    const audio = this._OpenSpeedyAudioClock();
    const layout = this.GetMainRunningLayout();
    const dodge = this._framerateMode === "vsync" && layout?.GetName() === "Dodge"
        && !this.IsExportToVideo();
    const previous = this._openSpeedyClock;
    const clock = this._openSpeedyClock = { frame, perf, audio, dodge, tick: frame, kind: 0 };
    const frameGap = previous ? frame - previous.frame : 0;
    const reset = !previous || previous.tick !== this._lastTickTime
        || !(frameGap > 0 && frameGap <= 600);

    if (!dodge || reset || !previous.dodge || this.IsSuspended()) {
        if (previous && (previous.dodge || reset)) {
            this._lastTickTime = !reset && !dodge ? previous.frame : frame;
            if (this._fpsLastTime > frame || reset) this._fpsLastTime = frame;
        }
        return this.Tick(frame);
    }

    const perfGap = perf - previous.perf;
    const audioGap = audio - previous.audio;
    const realAudio = audioGap >= 4 && audioGap <= 85;
    const wallGap = realAudio ? audioGap : frameGap;
    const diff = perfGap - frameGap;
    const splitClocks = Math.abs(diff) > Math.max(2.5, frameGap * 0.12)
        && perfGap <= 25 * frameGap + 20;
    const bothScaled = frameGap >= 65 && Math.abs(diff) < frameGap * 0.3
        && (realAudio ? perfGap / audioGap >= 1.8 : !(audioGap > 85) && frameGap >= 100);
    if (perfGap > 0 && perfGap <= 600) {
        clock.kind = bothScaled ? 2 : splitClocks ? Math.sign(diff) : 0;
    }
    const scaled = clock.kind !== 0 && clock.kind === previous.kind;
    const maxStep = Math.min(25, 1000 * this._maxDt);
    if (!scaled || !(maxStep > 0) || this._timeScale === 0) {
        // A first long gap is ambiguous: leave the game's original delta cap in charge.
        this._lastTickTime = previous.frame;
        if (this._fpsLastTime > frame) this._fpsLastTime = frame;
        return this.Tick(frame);
    }

    const admitted = Math.min(perfGap, 24 * maxStep);
    const count = Math.ceil(admitted / maxStep);
    const start = this._lastTickTime;
    if (count === 1) {
        clock.tick = start + admitted;
        return this.Tick(clock.tick);
    }

    // Convert the work cap to the possibly hooked performance clock's units.
    const reference = clock.kind === 2 && !realAudio ? 1000 / 60 : wallGap;
    const workLimit = 8 * Math.min(30, Math.max(0.1, perfGap / reference));
    const began = performance.now();
    const audioBegan = this._OpenSpeedyAudioClock();
    const spentBudget = () => performance.now() - began >= workLimit
        || (realAudio && this._OpenSpeedyAudioClock() - audioBegan >= 8);
    clock.tick = start;
    this._openSpeedyTickBatch = true;
    let painted = false;
    let finished = false;
    try {
        for (let i = 1; i <= count; ++i) {
            if (this.IsSuspended() || this.GetMainRunningLayout() !== layout
                || clock.tick !== this._lastTickTime || (i > 1 && spentBudget())) break;
            clock.tick = start + admitted * i / count;
            await this.Tick(clock.tick, false, i === count ? undefined : "skip-render");
            painted = i === count;
        }
        if (!painted && !this.IsSuspended()) this.Render();
        finished = true;
    } finally {
        this._openSpeedyTickBatch = false;
        if (finished && !this.IsSuspended()) this._RequestAnimationFrame();
    }
}
