"""Build the opt-in local CLI for a real Fragile run."""
from pathlib import Path

import minutescape_skills_packager as skills


def patch_runtime(stock, speed, features):
    commands = Path(__file__).with_name('minutescape_challenge_cli.js').read_bytes()
    runtime = skills.patch_runtime(stock, speed, features + b'\n' + commands)
    call = b'    this._MinutescapeAutoFarmTick();'
    runtime = skills.prior.patch.replace_once(runtime, call, call + b'\n    this._MinutescapeChallengeCliTick();')
    init = b'async Init(e){C3.CommonACES_SetRuntime(this),'
    return skills.prior.patch.replace_once(runtime, init, init + b'this._MinutescapeChallengeCliTick(true),')


if __name__ == '__main__':
    engine = skills.prior.patch
    engine.__doc__ = __doc__
    engine.PREVIOUS_SHA256 = 'd08763e4ddb3eaec456a5db88b0e5b7224f3c07ca8276de98d30b590fc79efda'
    engine.BACKUP_SUFFIX = '.before-fragile-cli-v3'
    engine.DEFAULT_SPEED = 'minutescape_speed_resilient.js'
    engine.DEFAULT_PATROL = 'minutescape_patrol_challenges.js'
    engine.patch_runtime = patch_runtime
    engine.main()
