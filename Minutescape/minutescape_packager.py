"""Build, install or restore the Minutescape OpenSpeedy compatibility patch."""

import argparse
import copy
import csv
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


STOCK_SHA256 = 'be9f864e19141b337b2f43cd1e4f54a7632bacda5bb310e86850a986aaf43119'
RUNTIME = 'scripts/c3runtime.js'
METHOD_ANCHOR = b'async Tick(e,t,s){'
CALLBACK = b'normal:e=>{this._rafId=-1,this._ruafId=-1,this.Tick(e)}'
SCHEDULE = b'_RequestAnimationFrame(){const e=this._tickCallbacks'
RESUME = b'this.HitBreakpoint()||this.Tick(e)}}_AddBehInstToTick(e){'
CHANGES = (
    (CALLBACK, CALLBACK.replace(b'.Tick(e)', b'._OpenSpeedyTick(e)')),
    (SCHEDULE, SCHEDULE.replace(b'{', b'{if(this._openSpeedyTickBatch)return;', 1)),
    (RESUME, RESUME.replace(b'||this.Tick(e)', b'||this._openSpeedyTickBatch||this.Tick(e)')),
)


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require_hash(path, expected):
    actual = sha256(path)
    if actual != expected:
        raise ValueError(f'Unexpected SHA-256 for {path}: {actual}. No replacement performed.')


def patched_runtime(original, fragment):
    if original.count(METHOD_ANCHOR) != 1 or b'_OpenSpeedyTick(' not in fragment or not fragment.strip():
        raise ValueError('Missing or ambiguous runtime patch methods')
    result = original
    for before, after in CHANGES:
        if result.count(before) != 1:
            raise ValueError(f'Missing or ambiguous runtime patch anchor: {before!r}')
        result = result.replace(before, after, 1)
    return result.replace(METHOD_ANCHOR, b'\n' + fragment + b'\n' + METHOD_ANCHOR, 1)


def verify_members(original, patched, fragment):
    with zipfile.ZipFile(original) as stock, zipfile.ZipFile(patched) as new:
        names = stock.namelist()
        if names.count(RUNTIME) != 1 or len(set(names)) != len(names) or new.namelist() != names:
            raise ValueError('ZIP membership or entry order changed')
        if new.comment != stock.comment:
            raise ValueError('ZIP archive comment changed')
        for name in names:
            old_entry, new_entry = stock.getinfo(name), new.getinfo(name)
            for key in ('date_time', 'compress_type', 'comment', 'extra', 'external_attr', 'internal_attr'):
                if getattr(old_entry, key) != getattr(new_entry, key):
                    raise ValueError(f'ZIP member metadata changed: {name} ({key})')
            data = stock.read(old_entry)
            expected = patched_runtime(data, fragment) if name == RUNTIME else data
            if new.read(new_entry) != expected:
                raise ValueError(f'Unexpected ZIP member data: {name}')


def build_to(original, destination, fragment):
    require_hash(original, STOCK_SHA256)
    with zipfile.ZipFile(original) as stock, zipfile.ZipFile(destination, 'w') as new:
        new.comment = stock.comment
        for item in stock.infolist():
            data = stock.read(item)
            if item.filename == RUNTIME:
                data = patched_runtime(data, fragment)
            entry = copy.copy(item)
            new.writestr(entry, data)
            # ZipFile fills in default permissions when the stock DOS attribute is zero.
            entry.external_attr = item.external_attr
    verify_members(original, destination, fragment)
    require_hash(original, STOCK_SHA256)


@contextmanager
def staged_path(destination):
    with tempfile.NamedTemporaryFile(prefix='.minutescape-', suffix='.nw', dir=destination.parent,
                                     delete=False) as temp:
        stage = Path(temp.name)
    try:
        yield stage
    finally:
        stage.unlink(missing_ok=True)


def require_closed():
    if os.name != 'nt':
        raise ValueError('Install and restore require Windows; build is platform independent.')
    result = subprocess.run(['tasklist.exe', '/FI', 'IMAGENAME eq Minutescape.exe', '/FO', 'CSV', '/NH'],
                            capture_output=True, text=True, errors='replace', check=True,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    if any(row and row[0].casefold() == 'minutescape.exe' for row in csv.reader(result.stdout.splitlines())):
        raise ValueError('Close Minutescape normally before installing or restoring the patch.')


def build(original, destination, fragment):
    if destination.exists():
        raise FileExistsError(f'Output already exists: {destination}')
    with staged_path(destination) as stage:
        build_to(original, stage, fragment)
        os.link(stage, destination)  # Publish a verified file, without overwriting an existing path.
    print(f'Built {destination}\nSHA-256: {sha256(destination)}')


def install(package, backup, fragment):
    require_closed()
    if backup.exists():
        raise FileExistsError(f'Backup already exists: {backup}')
    with staged_path(package) as stage, staged_path(backup) as saved:
        build_to(package, stage, fragment)
        shutil.copyfile(package, saved)
        require_hash(saved, STOCK_SHA256)
        os.link(saved, backup)
        require_hash(package, STOCK_SHA256)
        require_closed()
        os.replace(stage, package)
    print(f'Installed {package}\nStock backup: {backup}\nSHA-256: {sha256(package)}')


def restore(package, backup, fragment):
    require_closed()
    require_hash(backup, STOCK_SHA256)
    installed_hash = sha256(package)
    verify_members(backup, package, fragment)  # Refuse to overwrite Steam updates or unrelated mods.
    with staged_path(package) as stage:
        shutil.copyfile(backup, stage)
        require_hash(stage, STOCK_SHA256)
        require_hash(package, installed_hash)
        require_closed()
        os.replace(stage, package)
    print(f'Restored {package}\nStock backup remains at {backup}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fragment', type=Path, default=Path(__file__).with_name('minutescape_speed.js'))
    commands = parser.add_subparsers(dest='mode', required=True)
    for mode, help_text, other_arg in (
        ('build', 'Generate a patched copy; never touch the source.', 'output'),
        ('install', 'Back up and replace the stock package.', 'backup'),
        ('restore', 'Restore stock only if the installed package matches this patch.', 'backup'),
    ):
        command = commands.add_parser(mode, help=help_text)
        command.add_argument('package', type=Path)
        command.add_argument(other_arg, type=Path)
    args = parser.parse_args()
    other = args.output if args.mode == 'build' else args.backup
    try:
        {'build': build, 'install': install, 'restore': restore}[args.mode](
            args.package.resolve(), other.resolve(), args.fragment.read_bytes())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
