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
    const perfGap = perf - previous?.perf;
    const audioGap = audio - previous?.audio;
    const realAudio = audioGap >= 2 && audioGap <= 85;
    const reset = !previous || previous.tick !== this._lastTickTime || audioGap > 85
        || !(frameGap > 0 && frameGap <= 6000 && perfGap > 0 && perfGap <= 6000);
    if (reset || !dodge || !previous.dodge) this._openSpeedyBackgroundDt = 0;

    if (reset || this.IsSuspended()) {
        if (previous) {
            this._lastTickTime = frame;
            if (this._fpsLastTime > frame || reset) this._fpsLastTime = frame;
        }
        return this.Tick(frame);
    }

    const diff = perfGap - frameGap;
    const splitClocks = Math.abs(diff) > Math.max(2.5, frameGap * 0.12)
        && perfGap <= 160 * frameGap + 20;
    const bothScaled = frameGap >= 65 && Math.abs(diff) < frameGap * 0.3
        && (realAudio ? perfGap / audioGap >= 1.8 : frameGap >= 100);
    const audioConfirms = perfGap >= 65 && (realAudio ? perfGap / audioGap >= 3
        : previous.kind === 3 && (bothScaled || splitClocks));
    clock.kind = audioConfirms ? 3 : bothScaled ? 2 : splitClocks ? Math.sign(diff) : 0;
    const scaled = clock.kind !== 0 && previous.kind !== 0
        && (clock.kind === previous.kind || clock.kind === 3 || previous.kind === 3);
    const lastRate = scaled ? previous.rate : 0;
    const reference = realAudio ? audioGap : clock.kind >= 2 ? 1000 / 60 : frameGap;
    const sampleRate = Math.min(160, Math.max(0.1, perfGap / reference));
    // Audio advances in blocks; smooth that quantization when converting a CPU budget.
    const rate = clock.rate = lastRate && (realAudio || clock.kind < 2)
        ? lastRate * 0.75 + sampleRate * 0.25 : lastRate || sampleRate;
    const high = rate >= 40 || perfGap > 600;
    const maxStep = high ? 1000 * this._maxDt : Math.min(25, 1000 * this._maxDt);
    if (!dodge || !previous.dodge || !scaled || !(maxStep > 0) || this._timeScale === 0) {
        // A first long gap is ambiguous: leave the game's original delta cap in charge.
        this._lastTickTime = previous.frame;
        if (this._fpsLastTime > frame) this._fpsLastTime = frame;
        if (!dodge && scaled && (frameGap > 500 || (high && clock.kind >= 2))) {
            this._lastTickTime = frame - (realAudio ? audioGap : 1000 / 60);
        }
        return this.Tick(frame);
    }

    const admitted = Math.min(perfGap, (high ? 120 : 24) * maxStep);
    const count = Math.ceil(admitted / maxStep);
    const start = this._lastTickTime;
    if (count === 1) {
        clock.tick = start + admitted;
        return this.Tick(clock.tick);
    }

    // Convert the work cap to the possibly hooked performance clock's units.
    const budget = high ? 11 : 8;
    const workLimit = budget * rate;
    const began = performance.now();
    const audioBegan = this._OpenSpeedyAudioClock();
    const spentBudget = () => performance.now() - began >= workLimit
        || (realAudio && this._OpenSpeedyAudioClock() - audioBegan >= budget);
    clock.tick = start;
    this._openSpeedyTickBatch = true;
    let painted = false;
    let finished = false;
    try {
        for (let i = 1; i <= count; ++i) {
            if (this.IsSuspended() || this.GetMainRunningLayout() !== layout
                || clock.tick !== this._lastTickTime || (i > 1 && spentBudget())) break;
            clock.tick = start + admitted * i / count;
            this._openSpeedySkipBackground = high && i > 1;
            await this.Tick(clock.tick, false, i === count ? undefined : "skip-render");
            painted = i === count;
        }
        if (!painted && !this.IsSuspended()) this.Render();
        finished = true;
    } finally {
        this._openSpeedySkipBackground = false;
        this._openSpeedyTickBatch = false;
        if (finished && !this.IsSuspended()) this._RequestAnimationFrame();
    }
}
