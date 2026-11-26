"""Prepare candidate routes from a primary run and its already-running peers."""

import argparse
import json
from pathlib import Path
from time import monotonic, sleep

from parallel_playtest import start_recovery


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("main", type=Path, help="Primary run.jsonl")
    parser.add_argument("peers", type=Path, nargs="*", help="Other playtest run.jsonl files")
    parser.add_argument("--cache", type=Path, required=True, help="Shared prepared routes directory")
    parser.add_argument("--seconds", type=float, default=900)
    parser.add_argument("--keys-only", action="store_true")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    attempted = set()
    job = None
    limit = monotonic() + args.seconds
    while monotonic() < limit:
        with args.main.open("rb") as stream:
            stream.seek(max(0, args.main.stat().st_size - 10000))
            lines = stream.read().splitlines()
        for line in lines[1:]:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("event") == "ending":
                return
        if job is None or job.poll() is not None:
            job = start_recovery(args, [*args.peers, args.main], args.main.with_name("peer-recovery.log"), attempted)
        sleep(3)


if __name__ == "__main__":
    main()
