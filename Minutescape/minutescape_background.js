_MinutescapeCanRunInBackground() {
    return this.IsNWjs() && !this.IsPreview() && !this.IsExportToVideo()
        && this._framerateMode === "vsync" && typeof document !== "undefined";
}

_MinutescapeBackgroundWanted() {
    return this._MinutescapeCanRunInBackground()
        && (document.visibilityState === "hidden" || !document.hasFocus());
}

_MinutescapeCancelBackgroundTimer() {
    if (this._minutescapeBackgroundTimer != null) clearTimeout(this._minutescapeBackgroundTimer);
    this._minutescapeBackgroundTimer = null;
}

_MinutescapeRefreshBackgroundMode() {
    if (!this._hasStartedTicking || !this._MinutescapeCanRunInBackground()) return;
    const background = this._MinutescapeBackgroundWanted();
    if (background === this._minutescapeBackgroundMode) {
        if (background && this._minutescapeBackgroundTimer == null && !this._isInTick
            && !this._openSpeedyTickBatch && !this._minutescapeBackgroundTicking && !this.IsSuspended()) {
            this._RequestAnimationFrame();
        }
        return;
    }
    this._CancelAnimationFrame();
    if (!background) this._needRender = true;
    if (!this.IsSuspended() && !this._isInTick && !this._minutescapeBackgroundTicking) {
        this._RequestAnimationFrame();
    }
}

_MinutescapeWatchBackground() {
    if (!this.IsNWjs() || this.IsPreview() || typeof document === "undefined") return;
    const refresh = () => this._MinutescapeRefreshBackgroundMode();
    document.addEventListener("visibilitychange", refresh);
    self.addEventListener("focus", refresh);
    self.addEventListener("blur", refresh);
    // A renderer can stop delivering rAF without a timely C3 visibility message.
    setInterval(refresh, 500);
}

_MinutescapeScheduleBackground() {
    const background = this._MinutescapeBackgroundWanted();
    if (background !== this._minutescapeBackgroundMode) {
        const hadMode = this._minutescapeBackgroundMode !== undefined;
        this._minutescapeBackgroundMode = background;
        if (hadMode) {
            // A rAF timestamp and now() may use different native clocks.
            // Retain neither a mixed interval nor pending decorative time.
            this._openSpeedyClock = null;
            this._lastTickTime = 0;
            this._dt1 = 0;
            this._openSpeedyBackgroundDt = 0;
        }
    }
    if (!background) return false;
    if (this.IsSuspended() || this._minutescapeBackgroundTimer != null) return true;
    const rate = this._openSpeedyClock?.calibrationRate;
    const delay = Math.max(16, Math.min(80, 16 * (rate || 1)));
    this._minutescapeBackgroundTimer = setTimeout(async () => {
        this._minutescapeBackgroundTimer = null;
        if (this.IsSuspended()) return;
        if (!this._MinutescapeBackgroundWanted() || this._isInTick || this._openSpeedyTickBatch) {
            this._RequestAnimationFrame();
            return;
        }
        this._minutescapeBackgroundTicking = true;
        try {
            await this._OpenSpeedyTick(performance.now());
        } catch (error) {
            console.error("Minutescape background tick failed", error);
            return;
        } finally {
            this._minutescapeBackgroundTicking = false;
        }
        this._RequestAnimationFrame();
    }, delay);
    return true;
}
