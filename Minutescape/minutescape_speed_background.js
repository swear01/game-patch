// Substep the native OpenSpeedy clock; never multiply by the GUI's global factor.
_OpenSpeedyAudioClock() {
    try { return 1000 * globalThis.C3_GetAudioContextCurrentTime?.(); }
    catch { return NaN; }
}

_OpenSpeedyRateHint(perf) {
    // Use the app's selected factor to size the CPU budget when WebAudio
    // follows the hooked clock. The elapsed simulation still comes from the
    // native clock samples, and this value is never multiplied into dt.
    if (!this.IsNWjs?.()) return 0;
    const cache = this._openSpeedyRateHint ??= { next: -Infinity, rate: 0, last: 0 };
    if (perf >= cache.last && perf < cache.next) return cache.rate;
    cache.last = perf;
    try {
        const fs = require("fs"), path = require("path");
        const roaming = (self["process"] || nw["process"]).env.APPDATA;
        const config = JSON.parse(fs.readFileSync(path.join(roaming, "com.game1024.openspeedy", "settings.json"), "utf8"));
        const rate = config.settings?.speed;
        cache.rate = Number.isFinite(rate) && rate >= 3 && rate <= 15 ? rate : 0;
    } catch {
        cache.rate = 0;
    }
    cache.next = perf + 1500 * Math.max(1, cache.rate);
    return cache.rate;
}

async _OpenSpeedyTick(frame) {
    const background = this._minutescapeBackgroundTicking;
    const output = background ? "skip-render" : undefined;
    const perf = performance.now();
    const audio = this._OpenSpeedyAudioClock();
    const layout = this.GetMainRunningLayout();
    const dodge = this._framerateMode === "vsync" && layout?.GetName() === "Dodge"
        && !this.IsExportToVideo();
    const previous = this._openSpeedyClock;
    const clock = this._openSpeedyClock = { frame, perf, audio, dodge, tick: frame, kind: 0,
        calibrationRate: previous?.calibrationRate, calibrationMode: previous?.calibrationMode, layout };
    const frameGap = previous ? frame - previous.frame : 0;
    const perfGap = perf - previous?.perf;
    const audioGap = audio - previous?.audio;
    const realAudio = audioGap >= 2 && audioGap <= 85;
    const wasSynced = previous && previous.tick === this._lastTickTime;
    const pastRate = previous?.rate ?? 1;
    const menuRate = realAudio && perfGap > 0 ? perfGap / audioGap : pastRate;
    // Upgrade animations and scheduled actions use real frame time even when a purchase
    // stalls long enough to cross the accelerated gameplay clock's reset threshold.
    if (this._framerateMode === "vsync" && layout?.GetName() === "Upgrade"
        && wasSynced && !this.IsSuspended() && !this.IsExportToVideo()
        && frameGap > 0 && perfGap >= 50 && menuRate >= 3) {
        const elapsed = realAudio ? audioGap : perfGap / pastRate;
        const uiDt = Math.min(1000 * this._maxDt, elapsed);
        this._lastTickTime = frame - uiDt;
        if (this._fpsLastTime > frame) this._fpsLastTime = frame;
        clock.kind = 3;
        clock.rate = Math.min(160, menuRate);
        return this.Tick(frame, false, output);
    }
    // Decide pauses in real milliseconds once the native clock shape is known.
    // At 100x, a healthy 75ms display frame is 7500 native ms, not a long pause.
    const realGapLimit = 85;
    const mediumGapLimit = 500;
    const positiveClocks = frameGap > 0 && perfGap > 0;
    const coherentClocks = positiveClocks && Math.abs(frameGap - perfGap) <= 0.3 * frameGap;
    const diff = perfGap - frameGap;
    const splitClocks = positiveClocks && Math.abs(diff) > Math.max(2.5, frameGap * 0.12)
        && perfGap <= 160 * frameGap + 20;
    const hint = dodge ? this._OpenSpeedyRateHint(perf) : 0;
    const hintedNativeGap = hint >= 3 && perfGap >= Math.max(34, 4 * hint) && perfGap <= 500
        && (coherentClocks || (splitClocks && perfGap / frameGap >= 1.8));
    const priorRate = previous?.calibrationRate;
    const priorShape = previous?.calibrationMode === "both" ? coherentClocks
        : previous?.calibrationMode === "perf" && splitClocks && priorRate >= 3
            && Math.abs(perfGap / frameGap - priorRate) <= 0.35 * priorRate;
    const priorHealthyGap = priorRate >= 3 && priorShape && perfGap / priorRate <= realGapLimit;
    const calibrationAudio = audioGap >= 2 && audioGap <= mediumGapLimit;
    const audioRate = calibrationAudio && perfGap > 0 ? perfGap / audioGap : 0;
    const audioShape = coherentClocks ? "both" : splitClocks ? "perf" : null;
    const mediumAudioSample = audioGap > realGapLimit && calibrationAudio
        && audioRate >= 3 && audioRate <= 160 && audioShape;
    const continuousAudio = wasSynced && !this.IsSuspended() && previous?.layout === layout
        && previous?.mediumAudioShape === audioShape && previous?.mediumAudioRate >= 3
        && Math.abs(audioRate - previous.mediumAudioRate) <= 0.2 * previous.mediumAudioRate;
    clock.mediumAudioRate = mediumAudioSample ? audioRate : undefined;
    clock.mediumAudioShape = mediumAudioSample ? audioShape : undefined;
    clock.mediumAudioCount = mediumAudioSample && !this.IsSuspended()
        ? (continuousAudio ? previous.mediumAudioCount ?? 0 : 0) + 1 : 0;
    const stableMediumAudio = clock.mediumAudioCount >= 2;
    // Prefer already coherent native clocks over a delayed WebAudio block. A real
    // short audio sample can still calibrate a changed multiplier immediately.
    const audioCalibrated = audioRate >= 3 && audioRate <= 160
        && (coherentClocks || splitClocks) && (realAudio || !priorHealthyGap || stableMediumAudio);
    if (audioCalibrated) {
        clock.calibrationRate = audioRate;
        clock.calibrationMode = coherentClocks ? "both" : "perf";
    }
    const calibratedRate = audioCalibrated ? audioRate : priorRate;
    const knownFastClocks = calibratedRate >= 3 && (audioCalibrated || priorShape);
    const estimatedGap = knownFastClocks ? perfGap / calibratedRate : NaN;
    const healthyFastGap = knownFastClocks && estimatedGap <= realGapLimit;
    const mediumFastGap = knownFastClocks && estimatedGap > realGapLimit && estimatedGap <= mediumGapLimit;
    const continuousShape = wasSynced && previous?.layout === layout
        && previous?.calibrationMode === clock.calibrationMode;
    // Drop an isolated stall. Repeated, consistently measured slow display frames
    // must keep making bounded progress instead of resetting forever. No skipped
    // interval is queued for a later frame.
    clock.slowFrames = mediumFastGap && !this.IsSuspended()
        ? (continuousShape ? previous.slowFrames ?? 0 : 0) + 1 : 0;
    const acceptedFastGap = healthyFastGap || (mediumFastGap && clock.slowFrames >= 2);
    const reset = !wasSynced || !positiveClocks
        || (!hintedNativeGap && (audioGap > realGapLimit && !acceptedFastGap
            || (knownFastClocks ? !acceptedFastGap : frameGap > 6000 || perfGap > 6000)));
    if (reset || !dodge || !previous.dodge) this._openSpeedyBackgroundDt = 0;

    if (reset || this.IsSuspended()) {
        // Keep only audio-verified calibration through a discarded gap. The next
        // normal frame can recover; no discarded elapsed time becomes backlog.
        if (clock.calibrationRate >= 3) {
            clock.rate = clock.calibrationRate;
            clock.kind = 3;
        }
        if (previous) {
            this._lastTickTime = frame;
            if (this._fpsLastTime > frame || reset) this._fpsLastTime = frame;
        }
        return this.Tick(frame, false, output);
    }

    const bothScaled = frameGap >= 65 && Math.abs(diff) < frameGap * 0.3
        && (realAudio ? perfGap / audioGap >= 1.8 : frameGap >= 100);
    const audioConfirms = perfGap >= 65 && (realAudio ? perfGap / audioGap >= 3
        : previous.kind === 3 && (bothScaled || splitClocks));
    clock.kind = audioConfirms ? 3 : bothScaled ? 2 : splitClocks ? Math.sign(diff) : 0;
    const scaled = hintedNativeGap || knownFastClocks || (clock.kind !== 0 && previous.kind !== 0
        && (clock.kind === previous.kind || clock.kind === 3 || previous.kind === 3));
    const lastRate = scaled ? (knownFastClocks && !realAudio ? calibratedRate
        : previous.kind !== 0 ? previous.rate : 0) : 0;
    const reference = realAudio ? audioGap : clock.kind >= 2 ? 1000 / 60 : frameGap;
    const sampleRate = Math.min(160, Math.max(0.1, perfGap / reference));
    // Audio advances in blocks; smooth that quantization when converting a CPU budget.
    const rate = clock.rate = hintedNativeGap ? hint : lastRate && (realAudio || clock.kind < 2)
        ? lastRate * 0.75 + sampleRate * 0.25 : lastRate || sampleRate;
    const high = rate >= 40 || perfGap > 600;
    const fullBudget = high || (hintedNativeGap && hint >= 8);
    const maxStep = fullBudget ? 1000 * this._maxDt : Math.min(25, 1000 * this._maxDt);
    if (!dodge || !previous.dodge || !scaled || !(maxStep > 0) || this._timeScale === 0) {
        // A first long gap is ambiguous: leave the game's original delta cap in charge.
        this._lastTickTime = previous.frame;
        if (this._fpsLastTime > frame) this._fpsLastTime = frame;
        if (!dodge && scaled && (frameGap > 500 || (high && clock.kind >= 2))) {
            this._lastTickTime = frame - (realAudio ? audioGap : 1000 / 60);
        }
        return this.Tick(frame, false, output);
    }

    const admitted = Math.min(perfGap, (high ? 120 : 24) * maxStep);
    const count = Math.ceil(admitted / maxStep);
    const start = this._lastTickTime;
    if (count === 1) {
        clock.tick = start + admitted;
        return this.Tick(clock.tick, false, output);
    }

    // Convert the work cap to the possibly hooked performance clock's units.
    const budget = fullBudget ? 11 : 8;
    const workLimit = budget * rate;
    const began = performance.now();
    const audioBegan = this._OpenSpeedyAudioClock();
    const reliableBudgetAudio = realAudio && (!hintedNativeGap || Math.abs(audioRate - hint) <= 0.35 * hint);
    const spentBudget = () => performance.now() - began >= workLimit
        || (reliableBudgetAudio && this._OpenSpeedyAudioClock() - audioBegan >= budget);
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
            await this.Tick(clock.tick, false, i === count ? output : "skip-render");
            painted = i === count;
        }
        if (!background && !painted && !this.IsSuspended()) this.Render();
        finished = true;
    } finally {
        this._openSpeedySkipBackground = false;
        this._openSpeedyTickBatch = false;
        if (finished && !this.IsSuspended()) this._RequestAnimationFrame();
    }
}
