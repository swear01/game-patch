"""Build, add, or remove edge patrol while keeping Minutescape's OpenSpeedy patch."""

import argparse
import copy
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

import minutescape_packager as base


DIRECT_SHA256 = '29e2993ad2166413a58c905961b727955ce8ddadb73a40ffdbbef7312b572593'
DRAW = b'async _OpenSpeedyTick(frame) {'
SUBEVENTS = b'_RunSubEvents(){if(!this._subEvents.length)return;'
PATROL_CHECK = b'if(this._sid===944808599577142&&this._runtime._MinutescapePatrolMove())return;'
TIMING = ('date_time', 'compress_type', 'comment', 'extra', 'external_attr', 'internal_attr')


def replace_once(source, anchor, replacement):
    if source.count(anchor) != 1:
        raise ValueError(f'Missing or ambiguous patrol anchor: {anchor!r}')
    return source.replace(anchor, replacement, 1)


def patch_runtime(stock, speed, patrol):
    if (patrol.count(b'_MinutescapePatrolInput(') != 1 or
            patrol.count(b'_MinutescapePatrolMove(') != 1):
        raise ValueError('Missing or ambiguous patrol methods')
    speed = replace_once(speed, DRAW, DRAW + b'\n    this._MinutescapePatrolInput();')
    runtime = base.patched_runtime(stock, speed + b'\n' + patrol)
    return replace_once(runtime, SUBEVENTS, SUBEVENTS + PATROL_CHECK)


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
    base.require_hash(package, DIRECT_SHA256)
    with base.staged_path(package) as stage:
        build_to(stock, stage, speed, patrol)
        if not previous.exists():
            with base.staged_path(previous) as backup:
                shutil.copyfile(package, backup)
                base.require_hash(backup, DIRECT_SHA256)
                os.link(backup, previous)
        base.require_hash(previous, DIRECT_SHA256)
        base.require_hash(package, DIRECT_SHA256)
        base.require_closed()
        os.replace(stage, package)
    print(f'Upgraded {package}\nPrevious OpenSpeedy-only package: {previous}\nSHA-256: {base.sha256(package)}')


def restore(package, stock, previous, speed, patrol):
    base.require_closed()
    base.require_hash(stock, base.STOCK_SHA256)
    base.require_hash(previous, DIRECT_SHA256)
    digest = base.sha256(package)
    verify(stock, package, speed, patrol)
    with base.staged_path(package) as stage:
        shutil.copyfile(previous, stage)
        base.require_hash(stage, DIRECT_SHA256)
        base.require_hash(package, digest)
        base.require_closed()
        os.replace(stage, package)
    print(f'Restored OpenSpeedy-only package: {package}\nBackup remains at {previous}')


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--speed', type=Path, default=here / 'minutescape_speed.js')
    parser.add_argument('--patrol', type=Path, default=here / 'minutescape_patrol.js')
    commands = parser.add_subparsers(dest='mode', required=True)
    build_cmd = commands.add_parser('build', help='Build a new archive from verified stock')
    build_cmd.add_argument('stock', type=Path)
    build_cmd.add_argument('output', type=Path)
    for mode, help_text in (
        ('upgrade', 'Add patrol to a verified existing OpenSpeedy package'),
        ('restore', 'Remove patrol and leave the original OpenSpeedy patch installed'),
    ):
        command = commands.add_parser(mode, help=help_text)
        command.add_argument('package', type=Path)
        command.add_argument('stock', type=Path)
        command.add_argument('--previous', type=Path)
    args = parser.parse_args()
    try:
        speed = args.speed.read_bytes()
        patrol = args.patrol.read_bytes()
        stock = args.stock.resolve()
        if args.mode == 'build':
            build(stock, args.output.resolve(), speed, patrol)
        else:
            package = args.package.resolve()
            backup = (args.previous or package.with_name(package.name + '.before-patrol')).resolve()
            if len({stock, package, backup}) != 3:
                raise ValueError('Package and backups must be distinct paths')
            {'upgrade': upgrade, 'restore': restore}[args.mode](package, stock, backup, speed, patrol)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
