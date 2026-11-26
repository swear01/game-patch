"""Build or roll back the Minutescape patrol and upgrade drag fixes."""

import argparse
import copy
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

import minutescape_packager as base


PREVIOUS_SHA256 = 'c759bb370c0a43fa1d742409f6efa571d4e3d1946e4a992b49a699bcf9e8bde6'
DRAW = b'async _OpenSpeedyTick(frame) {'
SUBEVENTS = b'_RunSubEvents(){if(!this._subEvents.length)return;'
SUBEVENTS_BODY = (b'const t=this.IsGroup()&&this._runtime.IsCPUProfiling(),e=t?performance.now():0,'
                  b'n=this._eventStack,s=n.Push(this);this._isSolWriterAfterCnds?'
                  b'this._RunSubEvents_SolWriterAfterCnds(s):this._RunSubEvents_Fast(s),n.Pop(),'
                  b't&&(this._perfRecord.totalTimeCounter+=performance.now()-e)')
PATROL_CHECK = b'if(this._sid===944808599577142&&this._runtime._MinutescapePatrolMove())return;'
# Combine only the decorative background group's movement/fade delta once per display frame.
BACKGROUND_CHECK = (b'if(this._sid===799488624751281){const r=this._runtime;'
                    b'if((r._openSpeedySkipBackground||r._openSpeedyBackgroundDt>0)'
                    b'&&r.GetMainRunningLayout()?.GetName()==="Dodge"){const dt=r._dt;'
                    b'if(r._openSpeedySkipBackground){r._openSpeedyBackgroundDt+=dt;return;}'
                    b'r._dt+=r._openSpeedyBackgroundDt;r._openSpeedyBackgroundDt=0;try{'
                    + SUBEVENTS_BODY + b'}finally{r._dt=dt;}return;}}')
FAST_ACTIONS = b'_RunActions_Fast(t,e){const n=this._actions;'
DRAG_CHECK = (b'if(e===0){if(this._sid===226392173888185)this._runtime._MinutescapeUpgradeDrag(true);'
              b'else if(this._sid===874634095954579&&this._runtime._MinutescapeUpgradeDrag(false))e=1;}')
HTML_SYNC = b'this.PostComponentMessageToDOM("canvas","update-html-layer-dom-state",{"layersDomState":_._GetRootLayers().filter(e=>e.IsHTMLElementsLayer()).map(e=>e._GetHTMLLayerDOMState())})'
HTML_SYNC_NEEDED = b'(n||u!==-1||_._GetRootLayers().some(e=>e.IsHTMLElementsLayer()))&&'
TIMING = ('date_time', 'compress_type', 'comment', 'extra', 'external_attr', 'internal_attr')


def replace_once(source, anchor, replacement):
    if source.count(anchor) != 1:
        raise ValueError(f'Missing or ambiguous patch anchor: {anchor!r}')
    return source.replace(anchor, replacement, 1)


def patch_runtime(stock, speed, patrol):
    if (patrol.count(b'_MinutescapePatrolInput(') != 1 or
            patrol.count(b'_MinutescapePatrolMove(') != 1 or
            patrol.count(b'_MinutescapeAutoFarmInput(') != 1 or
            patrol.count(b'_MinutescapeAutoFarmTick(') != 1):
        raise ValueError('Missing or ambiguous patrol or auto-farm methods')
    speed = replace_once(speed, DRAW, DRAW + b'\n    this._MinutescapePatrolInput();'
                         b'\n    this._MinutescapeAutoFarmInput();\n    this._MinutescapeAutoFarmTick();')
    runtime = base.patched_runtime(stock, speed + b'\n' + patrol)
    runtime = replace_once(runtime, SUBEVENTS + SUBEVENTS_BODY,
                           SUBEVENTS + PATROL_CHECK + BACKGROUND_CHECK + SUBEVENTS_BODY)
    runtime = replace_once(runtime, FAST_ACTIONS, FAST_ACTIONS.replace(b'{', b'{' + DRAG_CHECK, 1))
    return replace_once(runtime, HTML_SYNC, HTML_SYNC_NEEDED + HTML_SYNC)


def verify(original, candidate, speed, patrol):
    with zipfile.ZipFile(original) as stock, zipfile.ZipFile(candidate) as new:
        names = stock.namelist()
        if names.count(base.RUNTIME) != 1 or len(set(names)) != len(names) or names != new.namelist():
            raise ValueError('Unexpected archive membership or order')
        if new.comment != stock.comment:
            raise ValueError('Unexpected archive comment')
        for item in stock.infolist():
            installed = new.getinfo(item.filename)
            if any(getattr(installed, key) != getattr(item, key) for key in TIMING):
                raise ValueError(f'Unexpected ZIP metadata: {item.filename}')
            data = stock.read(item)
            expected = patch_runtime(data, speed, patrol) if item.filename == base.RUNTIME else data
            if new.read(installed) != expected:
                raise ValueError(f'Unexpected ZIP data: {item.filename}')


def build_to(original, destination, speed, patrol):
    base.require_hash(original, base.STOCK_SHA256)
    with zipfile.ZipFile(original) as stock, zipfile.ZipFile(destination, 'w') as new:
        new.comment = stock.comment
        for item in stock.infolist():
            payload = stock.read(item)
            if item.filename == base.RUNTIME:
                payload = patch_runtime(payload, speed, patrol)
            entry = copy.copy(item)
            new.writestr(entry, payload)
            entry.external_attr = item.external_attr
    verify(original, destination, speed, patrol)
    base.require_hash(original, base.STOCK_SHA256)


def build(original, output, speed, patrol):
    if output.exists():
        raise FileExistsError(f'Output already exists: {output}')
    with base.staged_path(output) as stage:
        build_to(original, stage, speed, patrol)
        os.link(stage, output)
    print(f'Built {output}\nSHA-256: {base.sha256(output)}')


def upgrade(package, stock, previous, speed, patrol):
    base.require_closed()
    base.require_hash(package, PREVIOUS_SHA256)
    with base.staged_path(package) as stage:
        build_to(stock, stage, speed, patrol)
        if not previous.exists():
            with base.staged_path(previous) as backup:
                shutil.copyfile(package, backup)
                base.require_hash(backup, PREVIOUS_SHA256)
                os.link(backup, previous)
        base.require_hash(previous, PREVIOUS_SHA256)
        base.require_hash(package, PREVIOUS_SHA256)
        base.require_closed()
        os.replace(stage, package)
    print(f'Upgraded {package}\nPrevious patrol package: {previous}\nSHA-256: {base.sha256(package)}')


def restore(package, stock, previous, speed, patrol):
    base.require_closed()
    base.require_hash(stock, base.STOCK_SHA256)
    base.require_hash(previous, PREVIOUS_SHA256)
    digest = base.sha256(package)
    verify(stock, package, speed, patrol)
    with base.staged_path(package) as stage:
        shutil.copyfile(previous, stage)
        base.require_hash(stage, PREVIOUS_SHA256)
        base.require_hash(package, digest)
        base.require_closed()
        os.replace(stage, package)
    print(f'Restored previous patrol package: {package}\nBackup remains at {previous}')


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--speed', type=Path, default=here / 'minutescape_speed_high.js')
    parser.add_argument('--patrol', type=Path, default=here / 'minutescape_patrol_resized.js')
    parser.add_argument('--drag', type=Path, default=here / 'minutescape_upgrade_drag.js')
    parser.add_argument('--autofarm', type=Path, default=here / 'minutescape_autofarm.js')
    commands = parser.add_subparsers(dest='mode', required=True)
    build_cmd = commands.add_parser('build', help='Build a new archive from verified stock')
    build_cmd.add_argument('stock', type=Path)
    build_cmd.add_argument('output', type=Path)
    for mode, help_text in (
        ('upgrade', 'Install the layout fixes over the verified previous patrol package'),
        ('restore', 'Restore the previous patrol package'),
    ):
        command = commands.add_parser(mode, help=help_text)
        command.add_argument('package', type=Path)
        command.add_argument('stock', type=Path)
        command.add_argument('--previous', type=Path)
    args = parser.parse_args()
    try:
        speed = args.speed.read_bytes()
        patrol = b'\n'.join(path.read_bytes() for path in (args.patrol, args.drag, args.autofarm))
        stock = args.stock.resolve()
        if args.mode == 'build':
            build(stock, args.output.resolve(), speed, patrol)
        else:
            package = args.package.resolve()
            backup = (args.previous or package.with_name(package.name + '.before-layout-fixes')).resolve()
            if len({stock, package, backup}) != 3:
                raise ValueError('Package and backups must be distinct paths')
            {'upgrade': upgrade, 'restore': restore}[args.mode](package, stock, backup, speed, patrol)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
