"""Keep the installed desktop game ticking when another window has focus."""
from pathlib import Path

import minutescape_challenge_cli_packager as cli


engine = cli.skills.prior.patch
replace = engine.replace_once


def patch_runtime(stock, speed, features):
    background = Path(__file__).with_name('minutescape_background.js').read_bytes()
    runtime = cli.patch_runtime(stock, speed, features + b'\n' + background)
    init = b'this._MinutescapeChallengeCliTick(true),'
    runtime = replace(runtime, init, init + b'this._MinutescapeWatchBackground(),')
    startup = b'["isSuspended"]&&!this.IsExportToVideo()?'
    runtime = replace(runtime, startup, b'["isSuspended"]&&!this._MinutescapeCanRunInBackground()&&!this.IsExportToVideo()?')
    visibility = b'_OnVisibilityChange(e){if(!this._isAutoSuspendEnabled)return;'
    runtime = replace(runtime, visibility, visibility.replace(b'{', b'{if(this._MinutescapeCanRunInBackground()){this._MinutescapeRefreshBackgroundMode();return;}', 1))
    for signal in (b'_OnWindowBlur(e){this.IsPreview()', b'_OnWindowFocus(){this._isPausedOnBlur'):
        runtime = replace(runtime, signal, signal.replace(b'{', b'{this._MinutescapeRefreshBackgroundMode();', 1))
    schedule = b'_RequestAnimationFrame(){if(this._openSpeedyTickBatch)return;'
    runtime = replace(runtime, schedule,
                      b'_RequestAnimationFrame(){if(this._openSpeedyTickBatch||this._minutescapeBackgroundTicking||this._MinutescapeScheduleBackground())return;')
    resume = b'this.HitBreakpoint()||this._openSpeedyTickBatch||this.Tick(e)}}_AddBehInstToTick(e){'
    runtime = replace(runtime, resume, resume.replace(b'||this.Tick(e)', b'||this._minutescapeBackgroundTicking||this._isInTick||this.Tick(e)'))
    cancel = b'_CancelAnimationFrame(){-1!==this._rafId'
    return replace(runtime, cancel, b'_CancelAnimationFrame(){this._MinutescapeCancelBackgroundTimer();-1!==this._rafId')


def patch_member(name, data, speed, features):
    if name == engine.base.RUNTIME:
        return patch_runtime(data, speed, features)
    if name == 'package.json':
        flags = b'--disable-features=HardwareMediaKeyHandling'
        return replace(data, flags, flags + b',CalculateNativeWinOcclusion,IntensiveWakeUpThrottling'
                       b' --disable-background-timer-throttling --disable-renderer-backgrounding'
                       b' --disable-backgrounding-occluded-windows')
    return data


if __name__ == '__main__':
    engine.__doc__ = __doc__
    engine.PREVIOUS_SHA256 = '05dea2d09a39b056c1ef4e2c7f66a67ba49d0cffef5b496ea53c8fc2a78dcf8c'
    engine.BACKUP_SUFFIX = '.before-late-wave'
    engine.DEFAULT_SPEED = 'minutescape_speed_background.js'
    engine.DEFAULT_PATROL = 'minutescape_patrol_challenges.js'
    engine.patch_member = patch_member
    engine.main()
