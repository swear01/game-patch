"""Install or roll back automatic use of the two equipped abilities."""
import minutescape_refinement_packager as prior


CURRENT_SHA256 = '1295c9aa5f9aa9e2a5a51b5d1c0f82cad3031a964820e392e6542d7e603dd4ff'
BOOL_CONDITION = b'CompareBoolVar:e=>!!e.GetValue(),'
AUTO_SKILL = (b'CompareBoolVar(e){return!!e.GetValue()||'
              b'this._runtime._MinutescapeAutoSkillHeld(e.GetSID())},')
SHIELD_AIM = (b'if(e===0&&(this._sid===574588381872147||this._sid===696811881674733)'
              b'&&this._runtime._MinutescapeAutoShieldAim())e=1;')
SHIELD_CHARGE = (b'if(e===0&&(this._sid===121832084980495||this._sid===654351894916841))'
                 b'this._runtime._MinutescapeAutoShieldChargeStarted();'
                 b'if(e===0&&(this._sid===675434892797973||this._sid===929526932738405)'
                 b'&&this._runtime._MinutescapeAutoShieldPrepaid())e=1;')


def patch_runtime(stock, speed, features):
    if features.count(b'_MinutescapeAutoSkillHeld(sid)') != 1:
        raise ValueError('Missing or ambiguous automatic ability helper')
    runtime = prior.patch_runtime(stock, speed, features)
    runtime = prior.patch.replace_once(runtime, BOOL_CONDITION, AUTO_SKILL)
    anchor = b'_RunActions_Fast(t,e){'
    return prior.patch.replace_once(runtime, anchor, anchor + SHIELD_AIM + SHIELD_CHARGE)


if __name__ == '__main__':
    engine = prior.patch
    engine.__doc__ = __doc__
    engine.PREVIOUS_SHA256 = CURRENT_SHA256
    engine.BACKUP_SUFFIX = '.before-auto-skills'
    engine.DEFAULT_SPEED = 'minutescape_speed_upgrade_ui.js'
    engine.DEFAULT_PATROL = 'minutescape_patrol_skills.js'
    engine.patch_runtime = patch_runtime
    engine.main()
