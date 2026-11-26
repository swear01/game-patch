"""Run four independent Minimalism playtests and keep a log for each window."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


BOT = Path(__file__).with_name("minimalism_bot.py")
BUILDER = Path(__file__).with_name("plan_campaign.py")
RECOVERY = Path(__file__).with_name("recover_route.py")
ROUTES = ((1, 31), (8, 15), (16, 23), (24, 31))


def bot_command(args, folder, slot, start, end):
    return [
        sys.executable, "-u", str(BOT),
        "--game", str(args.game), "--umt", str(args.umt),
        "--work", str(folder / f"slot-{slot}"),
        "--speed", str(args.speed), "--attempts", str(args.attempts),
        "--plan-timeout", str(args.plan_timeout),
        "--slot", str(slot), "--start-level", str(start), "--stop-after-level", str(end),
        "--batch-steps", "96", "--verified", str(args.verified), "--learning", str(args.learning),
        *(["--cache", str(args.cache)] if args.cache else []),
        *(["--keys-only"] if args.keys_only else []),
        *(["--steam-achievements"] if slot == 1 and args.steam_achievements else []),
    ]


def start_preparation(args, folder):
    metadata = next((path.with_name("rooms.json") for path in folder.glob("slot-*/minimalism-*/run.jsonl")
                     if path.with_name("rooms.json").is_file()), None)
    if metadata is None:
        return None
    priority = sorted(range(1, 32), key=lambda level: (level - max(start for start, _ in ROUTES if start <= level), level))
    command = [
        sys.executable, "-u", str(BUILDER), str(metadata), *map(str, priority),
        "--output", str(args.cache), "--workers", str(args.planning_workers),
        "--attempts", "0", "1", "5", "11", "--plan-timeout", "15",
        "--learning", str(args.learning / args.build),
        *(["--keys-only"] if args.keys_only else []),
    ]
    with (folder / "preparation.log").open("wb") as stream:
        return subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)


def start_recovery(args, runs, log, attempted):
    for run in runs:
        with run.open("rb") as stream:
            stream.seek(max(0, run.stat().st_size - 20000))
            trailer = stream.read().splitlines()[1:]
        checkpoint = None
        timeouts = 0
        for line in reversed(trailer):
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event["event"] in ("clear", "ending", "segment_complete"):
                break
            if event["event"] == "planning_timeout":
                timeouts += 1
            if checkpoint is None and event["event"] == "checkpoint" and "player" in event:
                checkpoint = event
        if checkpoint is None or timeouts < 3 or checkpoint["tick"] < 150:
            continue
        level = checkpoint["level"]
        remaining = len(checkpoint["keys"]) + (0 if args.keys_only else len(checkpoint["symbols"]))
        signature = run, level, remaining
        if signature in attempted:
            continue
        attempted.add(signature)
        command = [sys.executable, "-u", str(RECOVERY), str(run.with_name("rooms.json")), str(run), str(level),
                   "--seconds", "25", "--candidates", "3", "--output", str(args.cache / f"planner-room-{level}.txt"),
                   *(["--keys-only"] if args.keys_only else [])]
        with log.open("ab") as stream:
            return subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
    return None


def play(args, folder):
    running = []
    failures = 0
    preparation = None
    recovery = None
    attempted = set()
    next_observation = 0
    try:
        for slot, (start, end) in enumerate(ROUTES, 1):
            log = folder / f"slot-{slot}.log"
            with log.open("wb") as stream:
                process = subprocess.Popen(
                    bot_command(args, folder, slot, start, end),
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                )
            running.append((slot, start, end, process, log))
            print(f"Slot {slot} started levels {start} through {end}. {log}", flush=True)

        while running:
            if preparation is None and args.planning_workers:
                preparation = start_preparation(args, folder)
            if args.planning_workers and time.monotonic() >= next_observation:
                next_observation = time.monotonic() + 3
                if recovery is None or recovery.poll() is not None:
                    runs = sorted(folder.glob("slot-*/minimalism-*/run.jsonl"))
                    recovery = start_recovery(args, runs, folder / "recovery.log", attempted)
            for row in running[:]:
                slot, start, end, process, log = row
                status = process.poll()
                if status is None:
                    continue
                running.remove(row)
                if status == 0:
                    print(f"Slot {slot} cleared levels {start} through {end}. {log}", flush=True)
                else:
                    failures += 1
                    print(f"Slot {slot} exited with code {status}. {log}", flush=True)
            if running:
                time.sleep(0.25)
    finally:
        for _, _, _, process, _ in running:
            if process.poll() is None:
                process.terminate()
            process.wait()

    print(f"{len(ROUTES) - failures}/{len(ROUTES)} slots completed. {folder}", flush=True)
    return int(failures > 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--umt", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--cache", type=Path, help="Optional prepared input plans for a replay comparison")
    parser.add_argument("--verified", type=Path, help="Shared output for routes cleared in the game")
    parser.add_argument("--learning", type=Path, help="Shared collision observations")
    parser.add_argument("--speed", type=int, choices=(1, 5), default=5)
    parser.add_argument("--keys-only", action="store_true", help="Run a door-only comparison without requiring symbols")
    parser.add_argument("--steam-achievements", action="store_true", help="Enable native Steam awards in the main window only")
    parser.add_argument("--attempts", type=int, default=40)
    parser.add_argument("--plan-timeout", type=float, default=2.5, help="Seconds allowed to plan at a checkpoint")
    parser.add_argument("--planning-workers", type=int, default=2, help="Background solvers preparing upcoming rooms")
    args = parser.parse_args()
    if not 0 < args.plan_timeout <= 60 or args.planning_workers < 0:
        parser.error("Planning timeout must be 0–60 seconds and worker count nonnegative.")
    suffix = "-keys" if args.keys_only else ""
    args.verified = args.verified or args.work / f"verified{suffix}"
    args.learning = args.learning or args.work / "learning"
    args.cache = args.cache or args.work / f"prepared{suffix}"
    args.build = hashlib.sha256(args.game.read_bytes()).hexdigest()[:16]
    for path in (args.work, args.verified, args.learning, args.cache):
        path.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="minimalism-parallel-", dir=args.work))
    return play(args, folder)


if __name__ == "__main__":
    raise SystemExit(main())
