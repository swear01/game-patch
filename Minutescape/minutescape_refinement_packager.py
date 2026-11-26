"""Install or roll back the Upgrade pacing and threat-avoidance update."""
from pathlib import Path

import minutescape_layout_packager as patch


HERE = Path(__file__).resolve().parent
BASE_BUILD_SHA256 = 'b00caf0b4918c97a41a5b5568ca6f0da0061bb1f6ec86d82acd8f5e4f2da6b4a'
_patch_runtime = patch.patch_runtime
AND = b'_RunAndBlock(t){const e=this._conditions;'
NEIGHBOURS = (b'if(this._sid===609015691615495&&this._runtime._MinutescapeUpgradeNeighbourXP())'
              b'{t.SetLastEventTrue(!1);return;}')
FAST = b'_RunActions_Fast(t,e){' + patch.DRAG_CHECK
RESET = b'if(e===0&&this._sid===399782854691094)this._runtime._minutescapeTreeIndex=undefined;'


def patch_runtime(stock, speed, features):
    neighbours = (HERE / 'minutescape_upgrade_neighbours.js').read_bytes()
    runtime = _patch_runtime(stock, speed + b'\n' + neighbours, features)
    runtime = patch.replace_once(runtime, FAST, FAST + RESET)
    return patch.replace_once(runtime, AND, AND.replace(b'{', b'{' + NEIGHBOURS, 1))


if __name__ == '__main__':
    import minutescape_layout_smart_packager as patch

    _patch_runtime = patch.patch_runtime
    patch.__doc__ = __doc__
    patch.PREVIOUS_SHA256 = BASE_BUILD_SHA256
    patch.BACKUP_SUFFIX = '.before-smart-patrol'
    patch.DEFAULT_SPEED = 'minutescape_speed_upgrade_ui.js'
    patch.DEFAULT_PATROL = 'minutescape_patrol_avoidance.js'
    patch.patch_runtime = patch_runtime
    patch.main()
